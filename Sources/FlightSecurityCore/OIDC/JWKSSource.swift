import AsyncHTTPClient
import Foundation
import JWTKit
import Logging
import NIOCore
import NIOFoundationCompat
import Synchronization

/// Where the IdP's public keys come from (design §3.2). The production
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

/// Fetches the JWKS over HTTP(S) (design §3.2).
///
/// When an explicit JWKS URL is configured, it is fetched directly. When
/// not, the standard OIDC discovery document
/// (`{issuer}/.well-known/openid-configuration`) is fetched once to find
/// `jwks_uri` — this is part of what makes Descope, Keycloak, Auth0, Okta,
/// and Entra pure *configuration* of one implementation (design §3.3):
/// their JWKS locations differ, but their discovery documents all point to
/// them. The discovered URL is cached for the life of the process; the
/// document's `issuer` must match the configured issuer exactly (OIDC
/// Discovery §4.3).
public final class HTTPJWKSSource: JWKSSource {
    private let issuer: String
    private let explicitJWKSURL: URL?
    private let http: any HTTPGetting
    private let logger: Logger
    private let discoveredJWKSURL = Mutex<URL?>(nil)

    public convenience init(
        issuer: String,
        jwksURL: URL? = nil,
        requestTimeout: Duration = .seconds(10)
    ) {
        self.init(
            issuer: issuer,
            jwksURL: jwksURL,
            http: AsyncHTTPGetter(timeout: requestTimeout),
            logger: Logger(label: "flight.security.jwks")
        )
    }

    init(issuer: String, jwksURL: URL?, http: any HTTPGetting, logger: Logger) {
        self.issuer = issuer
        self.explicitJWKSURL = jwksURL
        self.http = http
        self.logger = logger
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
        do {
            return try JSONDecoder().decode(JWKS.self, from: data)
        } catch {
            throw JWKSSourceError(reason: "JWKS document at \(url.absoluteString) failed to decode: \(error)")
        }
    }

    private func jwksURL() async throws -> URL {
        if let explicitJWKSURL { return explicitJWKSURL }
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
        guard let discoveryURL = URL(string: base + "/.well-known/openid-configuration"),
            discoveryURL.scheme == "https" || discoveryURL.scheme == "http"
        else {
            throw JWKSSourceError(reason: "issuer is not an HTTP(S) URL: \(issuer)")
        }

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

        // OIDC Discovery §4.3: the document must assert the issuer we asked
        // about — a mismatch means misconfiguration or a hostile endpoint.
        guard normalizedIssuer(document.issuer) == normalizedIssuer(issuer) else {
            throw JWKSSourceError(
                reason: "discovery document issuer \"\(document.issuer)\" does not match configured issuer \"\(issuer)\""
            )
        }

        guard let jwksURL = URL(string: document.jwksURI),
            jwksURL.scheme == "https" || jwksURL.scheme == "http"
        else {
            throw JWKSSourceError(reason: "discovery document jwks_uri is not an HTTP(S) URL: \(document.jwksURI)")
        }

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

    func getJSON(_ url: URL) async throws -> Data {
        var request = HTTPClientRequest(url: url.absoluteString)
        request.headers.add(name: "Accept", value: "application/json")
        let response = try await HTTPClient.shared.execute(
            request, timeout: TimeAmount(timeout)
        )
        guard response.status == .ok else {
            throw JWKSSourceError(
                reason: "GET \(url.absoluteString) returned HTTP \(response.status.code)"
            )
        }
        let body = try await response.body.collect(upTo: Self.maxResponseBytes)
        return Data(buffer: body)
    }
}
