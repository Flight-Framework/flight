import AsyncHTTPClient
import Foundation
import JWTKit
import Logging
import NIOCore
import NIOFoundationCompat
import Synchronization

/// Where the IdP's public keys come from. The production
/// implementation is ``HTTPJWKSSource``; tests substitute an in-memory one.
public protocol JWKSSource: Sendable {
    /// Fetches the current key set. Called by the cache on TTL expiry, on an
    /// unrecognized `kid`, and by the background maintenance service.
    func fetchKeys() async throws -> JWKS
}

/// A JWKS fetch failure, with detail for internal logs.
public struct JWKSSourceError: Error, Sendable, CustomStringConvertible {
    public let reason: String

    public init(reason: String) {
        self.reason = reason
    }

    public var description: String { "JWKS fetch failed: \(reason)" }
}

/// Whether a URL is allowed to carry key material.
///
/// Every one of these fetches decides which public keys will verify every
/// token this service accepts. An attacker who can answer one of them serves
/// their own signing key and mints any principal they like, so the transport
/// is not incidental to the security of this package — it is the security of
/// this package.
public enum JWKSTransportPolicy: Sendable, Equatable {
    /// HTTPS only. The only policy suitable for anything reachable from a
    /// network you do not own.
    case httpsOnly
    /// HTTPS, plus plaintext HTTP to loopback addresses.
    ///
    /// For a local IdP container during development. Loopback is the whole
    /// exemption: an attacker who can intercept traffic to 127.0.0.1 is
    /// already running as you.
    case allowInsecureLoopback
    /// Plaintext HTTP to anywhere.
    ///
    /// There is no safe use of this against a remote host. It exists for
    /// tests and for someone who has read this sentence and decided anyway.
    case allowInsecureAnywhere

    /// Rejects `url` unless this policy permits key material over it.
    func validate(_ url: URL, what: String) throws {
        switch url.scheme?.lowercased() {
        case "https":
            return
        case "http":
            switch self {
            case .allowInsecureAnywhere:
                return
            case .allowInsecureLoopback where url.isLoopback:
                return
            case .httpsOnly, .allowInsecureLoopback:
                throw JWKSSourceError(
                    reason: """
                        \(what) is plaintext HTTP (\(url.absoluteString)). Key material fetched \
                        over HTTP can be replaced in transit, and a replaced key set forges every \
                        token this service will accept. Use HTTPS, or set the transport policy \
                        deliberately if this is a local development IdP.
                        """)
            }
        default:
            throw JWKSSourceError(
                reason: "\(what) is not an HTTP(S) URL: \(url.absoluteString)")
        }
    }
}

extension URL {
    /// Whether this URL's host is a loopback address.
    var isLoopback: Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
            || host.hasSuffix(".localhost")
    }
}

/// Fetches the JWKS over HTTP(S).
///
/// When an explicit JWKS URL is configured, it is fetched directly. When
/// not, the standard OIDC discovery document
/// (`{issuer}/.well-known/openid-configuration`) is fetched once to find
/// `jwks_uri` — this is part of what makes Descope, Keycloak, Auth0, Okta,
/// and Entra pure *configuration* of one implementation:
/// their JWKS locations differ, but their discovery documents all point to
/// them. The discovered URL is cached for the life of the process; the
/// document's `issuer` must match the configured issuer exactly (OIDC
/// Discovery).
public final class HTTPJWKSSource: JWKSSource {
    private let issuer: String
    private let explicitJWKSURL: URL?
    private let http: any HTTPGetting
    private let logger: Logger
    private let policy: JWKSTransportPolicy
    private let discoveredJWKSURL = Mutex<URL?>(nil)

    public convenience init(
        issuer: String,
        jwksURL: URL? = nil,
        requestTimeout: Duration = .seconds(10),
        transportPolicy: JWKSTransportPolicy = .httpsOnly
    ) {
        self.init(
            issuer: issuer,
            jwksURL: jwksURL,
            http: AsyncHTTPGetter(timeout: requestTimeout, policy: transportPolicy),
            logger: Logger(label: "flight.security.jwks"),
            policy: transportPolicy
        )
    }

    init(
        issuer: String,
        jwksURL: URL?,
        http: any HTTPGetting,
        logger: Logger,
        policy: JWKSTransportPolicy = .httpsOnly
    ) {
        self.issuer = issuer
        self.explicitJWKSURL = jwksURL
        self.http = http
        self.logger = logger
        self.policy = policy
    }

    public func fetchKeys() async throws -> JWKS {
        let url = try await jwksURL()
        let data: Data
        do {
            data = try await http.getJSON(url)
        } catch let error as JWKSSourceError {
            throw error
        } catch {
            throw JWKSSourceError(reason: "GET \(url.absoluteString): \(error)")
        }
        let jwks: JWKS
        do {
            jwks = try JSONDecoder().decode(JWKS.self, from: data)
        } catch {
            throw JWKSSourceError(reason: "JWKS document at \(url.absoluteString) failed to decode: \(error)")
        }
        return filteredToSigningKeys(jwks, raw: data, url: url)
    }

    /// Drops keys the IdP published for something other than verifying
    /// signatures.
    ///
    /// A JWK may declare `use` ("sig"/"enc") or `key_ops`. Every key in the
    /// document was previously added to the verification collection
    /// regardless, so a key the IdP published *for encryption* would happily
    /// verify a token signed with its private half — the cross-protocol
    /// mistake those fields exist to prevent. JWTKit's `JWK` does not decode
    /// either field, so they are read from the raw document alongside it.
    private func filteredToSigningKeys(_ jwks: JWKS, raw: Data, url: URL) -> JWKS {
        struct KeyUse: Decodable {
            let kid: String?
            let use: String?
            let keyOps: [String]?
            enum CodingKeys: String, CodingKey {
                case kid, use
                case keyOps = "key_ops"
            }
        }
        struct Document: Decodable { let keys: [KeyUse] }

        guard let document = try? JSONDecoder().decode(Document.self, from: raw) else {
            return jwks  // Already decoded as a JWKS; nothing more to learn.
        }

        var rejected: [String: String] = [:]
        for key in document.keys {
            guard let kid = key.kid else { continue }
            if let use = key.use, use != "sig" {
                rejected[kid] = "use=\(use)"
            } else if let ops = key.keyOps, !ops.contains("verify") {
                rejected[kid] = "key_ops=\(ops.joined(separator: ","))"
            }
        }
        guard !rejected.isEmpty else { return jwks }

        logger.debug(
            "ignoring JWKS keys not published for signature verification",
            metadata: [
                "jwks_uri": "\(url.absoluteString)",
                "ignored": "\(rejected.map { "\($0.key) (\($0.value))" }.joined(separator: ", "))",
            ]
        )
        var filtered = jwks
        filtered.keys = jwks.keys.filter { key in
            guard let kid = key.keyIdentifier?.string else { return true }
            return rejected[kid] == nil
        }
        return filtered
    }

    private func jwksURL() async throws -> URL {
        if let explicitJWKSURL {
            // Checked every time rather than once at construction: this is the
            // path that skipped discovery entirely, and it was the one URL in
            // the package that nothing validated.
            try policy.validate(explicitJWKSURL, what: "the configured jwks_url")
            return explicitJWKSURL
        }
        if let cached = discoveredJWKSURL.withLock({ $0 }) { return cached }
        let discovered = try await discover()
        discoveredJWKSURL.withLock { $0 = discovered }
        return discovered
    }

    private struct DiscoveryDocument: Decodable {
        let issuer: String
        let jwksURI: String

        enum CodingKeys: String, CodingKey {
            case issuer
            case jwksURI = "jwks_uri"
        }
    }

    private func discover() async throws -> URL {
        let base = issuer.hasSuffix("/") ? String(issuer.dropLast()) : issuer
        guard let discoveryURL = URL(string: base + "/.well-known/openid-configuration") else {
            throw JWKSSourceError(reason: "issuer is not a URL: \(issuer)")
        }
        try policy.validate(discoveryURL, what: "the OIDC discovery endpoint")

        let data: Data
        do {
            data = try await http.getJSON(discoveryURL)
        } catch let error as JWKSSourceError {
            throw error
        } catch {
            throw JWKSSourceError(reason: "GET \(discoveryURL.absoluteString): \(error)")
        }

        let document: DiscoveryDocument
        do {
            document = try JSONDecoder().decode(DiscoveryDocument.self, from: data)
        } catch {
            throw JWKSSourceError(reason: "discovery document failed to decode: \(error)")
        }

        // OIDC Discovery: the document must assert the issuer we asked
        // about — a mismatch means misconfiguration or a hostile endpoint.
        guard normalizedIssuer(document.issuer) == normalizedIssuer(issuer) else {
            throw JWKSSourceError(
                reason: "discovery document issuer \"\(document.issuer)\" does not match configured issuer \"\(issuer)\""
            )
        }

        guard let jwksURL = URL(string: document.jwksURI) else {
            throw JWKSSourceError(
                reason: "discovery document jwks_uri is not a URL: \(document.jwksURI)")
        }
        // The discovery document is remote input. A hostile or compromised one
        // naming an http:// jwks_uri would have downgraded the fetch that
        // decides which keys are trusted.
        try policy.validate(jwksURL, what: "the discovered jwks_uri")

        logger.debug(
            "discovered JWKS endpoint",
            metadata: ["issuer": "\(issuer)", "jwks_uri": "\(jwksURL.absoluteString)"]
        )
        return jwksURL
    }

    private func normalizedIssuer(_ value: String) -> String {
        value.hasSuffix("/") ? String(value.dropLast()) : value
    }
}

/// Internal HTTP-GET seam so discovery/JWKS handling is testable without
/// sockets. Production uses `HTTPClient.shared` — a process-wide client
/// that needs no lifecycle management.
protocol HTTPGetting: Sendable {
    func getJSON(_ url: URL) async throws -> Data
}

struct AsyncHTTPGetter: HTTPGetting {
    /// JWKS documents are small; anything past this is not a key set.
    static let maxResponseBytes = 1_048_576

    let timeout: Duration
    let policy: JWKSTransportPolicy

    func getJSON(_ url: URL) async throws -> Data {
        var request = HTTPClientRequest(url: url.absoluteString)
        request.headers.add(name: "Accept", value: "application/json")
        let response = try await HTTPClient.shared.execute(
            request, timeout: TimeAmount(timeout)
        )

        // Validating the URL we asked for is not enough: the client follows
        // redirects, so an https:// endpoint answering `302 http://…` moved
        // the key fetch onto plaintext with nothing in this package noticing.
        // Every hop it actually took has to satisfy the policy too.
        for hop in response.history {
            guard let hopURL = URL(string: hop.request.url) else {
                throw JWKSSourceError(reason: "unparseable redirect target: \(hop.request.url)")
            }
            try policy.validate(hopURL, what: "a redirect target during the key fetch")
        }

        guard response.status == .ok else {
            throw JWKSSourceError(
                reason: "GET \(url.absoluteString) returned HTTP \(response.status.code)"
            )
        }
        let body = try await response.body.collect(upTo: Self.maxResponseBytes)
        return Data(buffer: body)
    }
}
