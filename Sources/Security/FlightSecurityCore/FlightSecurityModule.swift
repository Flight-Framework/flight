import FlightCore
import FlightWeb
import Logging
import ServiceLifecycle

/// Authentication wiring, independent of how tokens are validated.
///
/// Registers:
/// - the request-scoped ``PrincipalHolder`` carrying the principal;
/// - ``Authentication`` in its own `pipeline { }` call, ahead of whatever the
///   application declares in its own — see `Container.pipeline(_:)` for why
///   calling it more than once composes rather than conflicts.
///
/// It does **not** register a ``TokenValidator``. Supplying one is the
/// application's choice, made by listing a module:
///
/// - ``FlightOIDCModule`` for OIDC/JWT — the common case;
/// - any module of your own that registers `(any TokenValidator)`, for
///   session cookies, API keys, mTLS, HMAC, or anything else.
///
/// With neither, `(any TokenValidator)` is unregistered and ``Authentication``
/// fails to resolve it at container freeze — loudly, at startup, naming the
/// type.
///
/// ``RequireAuthentication`` is deliberately *not* added to any pipeline —
/// apps add it where wanted, since unlike authentication itself, enforcement
/// is not something every route wants.
///
/// ## Why the validator is not a default here
///
/// This module used to register an OIDC validator unless it found that the
/// application had already registered its own, by scanning
/// `container.allRegistrations()`. That seam depended on three implicit
/// things: the scan matching a type name, the application's module being
/// configured *before* this one (registering after it silently lost), and an
/// internal flag that also decided whether a JWKS refresher ran. Choosing a
/// module instead is explicit, order-independent, and visible at the
/// bootstrap call site.
public final class FlightSecurityModule: FlightModule {
    public init() {}

    public func configure(_ container: Container) throws {
        container.register(PrincipalHolder.self, scope: .scoped) { _ in
            PrincipalHolder()
        }

        container.pipeline {
            Authentication.self
        }
    }
}

/// OIDC/JWT token validation: the default implementation of the seam
/// ``FlightSecurityModule`` leaves open.
///
/// Registers ``OIDCTokenValidator`` — configured from `security.oidc.*` — as
/// `(any TokenValidator)`, and owns the JWKS maintenance service that keeps
/// its key cache warm. Both travel together, because both are OIDC's and
/// neither means anything without the other.
///
/// Missing required configuration (`security.oidc.issuer` / `audience`) fails
/// at container freeze — startup, not first request.
///
/// List this module to get OIDC. Omit it and register your own
/// `(any TokenValidator)` to authenticate any other way.
public final class FlightOIDCModule: FlightModule {
    public static var dependencies: [any FlightModule.Type] {
        [FlightSecurityModule.self]
    }

    private var container: Container?

    public init() {}

    public func configure(_ container: Container) throws {
        self.container = container

        container.register(OIDCSecurityConfiguration.self, scope: .singleton) { c in
            try OIDCSecurityConfiguration(configuration: c.resolve(Configuration.self))
        }
        container.register(OIDCTokenValidator.self, scope: .singleton) { c in
            OIDCTokenValidator(configuration: try c.resolve(OIDCSecurityConfiguration.self))
        }
        container.register((any TokenValidator).self, scope: .singleton) { c in
            try c.resolve(OIDCTokenValidator.self)
        }
    }

    public var service: (any Service)? {
        container.map { JWKSMaintenanceService(container: $0) }
    }
}

/// Keeps the process-wide JWKS cache warm: one fetch at
/// startup so the first request never pays IdP latency, then a refresh per
/// cache-TTL. Fetch failures are logged and retried on the next tick —
/// token validation falls back to lazy fetching (and stale-serving), so an
/// IdP blip never takes the app down.
///
/// Holds the container only because `FlightModule.service` is read before
/// `freeze()`, so the validator cannot be handed over at construction. That
/// indirection goes away with composition; see COMPOSITION-MIGRATION.md §3.
final class JWKSMaintenanceService: Service {
    private let container: Container
    private let logger = Logger(label: "flight.security.jwks")

    init(container: Container) {
        self.container = container
    }

    func run() async throws {
        // Unconditional now: this service belongs to FlightOIDCModule, which
        // registered the validator it maintains. Previously it lived on the
        // security module, could not know whether OIDC was in play, and had
        // to park forever when it wasn't.
        let validator = try container.resolve(OIDCTokenValidator.self)
        let interval = Duration.seconds(max(validator.keyRefreshInterval, 60))
        do {
            try await cancelWhenGracefulShutdown {
                await self.refresh(validator, context: "pre-warm")
                while !Task.isCancelled {
                    try await Task.sleep(for: interval)
                    await self.refresh(validator, context: "scheduled refresh")
                }
            }
        } catch is CancellationError {
            // Graceful shutdown.
        }
    }

    private func refresh(_ validator: OIDCTokenValidator, context: String) async {
        do {
            try await validator.refreshKeys()
            logger.debug("JWKS \(context) complete")
        } catch {
            logger.warning(
                "JWKS \(context) failed; validation will fetch lazily",
                metadata: ["reason": "\(error)"]
            )
        }
    }
}
