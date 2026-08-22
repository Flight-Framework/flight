import Foundation
import JWTKit
import Logging

/// Process-wide JWKS cache (design §3.2, §6).
///
/// Owns the orchestration the design calls "essential and easy to do
/// naively":
/// - **TTL caching** — keys are refetched only when `ttl` has elapsed, never
///   per-request.
/// - **Key rotation** — a token signed with an unrecognized `kid` triggers a
///   refresh, rate-limited by `refreshCooldown` so a stream of garbage
///   tokens cannot hammer the IdP.
/// - **Single-flight** — concurrent validations during a refresh share one
///   fetch.
/// - **Stale-serving** — if a refresh fails and cached keys exist, the stale
///   keys are served (and the failure logged) rather than failing every
///   request while the IdP endpoint blips; retries stay gated by the
///   cooldown.
actor JWKSCache {
    struct Snapshot: Sendable {
        let collection: JWTKeyCollection
        let keyIDs: Set<String>
    }

    enum RefreshHint: Sendable {
        /// Refresh only if the TTL has elapsed (the per-validate default).
        case ifStale
        /// A token carried a `kid` we do not know — refresh unless one was
        /// attempted within the cooldown window.
        case unknownKeyID
        /// Refresh unconditionally (background maintenance).
        case force
    }

    private let source: any JWKSSource
    private let ttl: TimeInterval
    private let refreshCooldown: TimeInterval
    private let now: @Sendable () -> Date
    private let logger: Logger

    private var current: Snapshot?
    private var fetchedAt: Date?
    private var lastAttemptAt: Date?
    private var inflight: Task<Snapshot, any Error>?

    init(
        source: any JWKSSource,
        ttl: TimeInterval,
        refreshCooldown: TimeInterval,
        now: @escaping @Sendable () -> Date = { Date() },
        logger: Logger = Logger(label: "flight.security.jwks")
    ) {
        self.source = source
        self.ttl = ttl
        self.refreshCooldown = refreshCooldown
        self.now = now
        self.logger = logger
    }

    func snapshot(_ hint: RefreshHint = .ifStale) async throws -> Snapshot {
        let moment = now()

        let wantsRefresh: Bool
        switch hint {
        case .force:
            wantsRefresh = true
        case .unknownKeyID:
            wantsRefresh = cooldownElapsed(at: moment)
        case .ifStale:
            // The cooldown gates the empty-cache case too: a cold start
            // against an unreachable IdP must not turn every bearer-token
            // request into an outbound fetch.
            let stale = fetchedAt.map { moment.timeIntervalSince($0) >= ttl } ?? true
            wantsRefresh = stale && cooldownElapsed(at: moment)
        }

        guard wantsRefresh else {
            if let current { return current }
            if let inflight {
                // A fetch is running right now (starting it is what closed
                // the cooldown gate) — join it rather than failing fast.
                do {
                    return try await inflight.value
                } catch {
                    throw TokenValidationError(
                        kind: .keySourceUnavailable, reason: String(describing: error)
                    )
                }
            }
            // No cached keys and the cooldown gate is closed: the last fetch
            // failed moments ago. Fail fast instead of hammering the IdP.
            throw TokenValidationError(
                kind: .keySourceUnavailable,
                reason: "no cached JWKS and last fetch attempt failed within the cooldown window"
            )
        }

        do {
            return try await refresh()
        } catch {
            if let current {
                logger.warning(
                    "JWKS refresh failed; serving cached keys",
                    metadata: ["reason": "\(error)"]
                )
                return current
            }
            throw TokenValidationError(
                kind: .keySourceUnavailable,
                reason: String(describing: error)
            )
        }
    }

    /// Single-flight refresh: concurrent callers await the same fetch.
    private func refresh() async throws -> Snapshot {
        if let inflight {
            return try await inflight.value
        }
        lastAttemptAt = now()
        let source = self.source
        let logger = self.logger
        let task = Task {
            let jwks = try await source.fetchKeys()
            return try await Self.buildSnapshot(from: jwks, logger: logger)
        }
        inflight = task
        defer { inflight = nil }
        let snapshot = try await task.value
        current = snapshot
        fetchedAt = now()
        logger.debug(
            "JWKS refreshed",
            metadata: ["keys": "\(snapshot.keyIDs.count)"]
        )
        return snapshot
    }

    private func cooldownElapsed(at moment: Date) -> Bool {
        guard let lastAttemptAt else { return true }
        return moment.timeIntervalSince(lastAttemptAt) >= refreshCooldown
    }

    /// Builds a fresh key collection from a fetched JWKS. Tolerant per key:
    /// a key the collection rejects (no `kid`, unsupported type) is skipped
    /// with a log line rather than poisoning the whole set — IdPs routinely
    /// publish encryption keys alongside signing keys.
    private static func buildSnapshot(from jwks: JWKS, logger: Logger) async throws -> Snapshot {
        let collection = JWTKeyCollection()
        var keyIDs: Set<String> = []
        for key in jwks.keys {
            do {
                try await collection.add(jwk: key)
                if let kid = key.keyIdentifier?.string {
                    keyIDs.insert(kid)
                }
            } catch {
                logger.notice(
                    "skipping JWKS key the key collection rejected",
                    metadata: [
                        "kid": "\(key.keyIdentifier?.string ?? "<none>")",
                        "reason": "\(error)",
                    ]
                )
            }
        }
        guard !keyIDs.isEmpty else {
            throw JWKSSourceError(reason: "JWKS document contained no usable signing keys")
        }
        return Snapshot(collection: collection, keyIDs: keyIDs)
    }
}
