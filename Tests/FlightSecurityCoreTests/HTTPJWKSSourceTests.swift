import Foundation
import Logging
import Synchronization
import Testing

@testable import FlightSecurityCore

/// Canned HTTP responses keyed by URL, recording every request.
private final class FakeHTTPGetter: HTTPGetting, Sendable {
    private struct State {
        var responses: [String: Result<Data, JWKSSourceError>] = [:]
        var requested: [String] = []
    }

    private let state = Mutex(State())

    func respond(to url: String, with body: String) {
        state.withLock { $0.responses[url] = .success(Data(body.utf8)) }
    }

    func fail(_ url: String, reason: String) {
        state.withLock { $0.responses[url] = .failure(JWKSSourceError(reason: reason)) }
    }

    var requested: [String] {
        state.withLock { $0.requested }
    }

    func getJSON(_ url: URL) async throws -> Data {
        let result: Result<Data, JWKSSourceError>? = state.withLock {
            $0.requested.append(url.absoluteString)
            return $0.responses[url.absoluteString]
        }
        guard let result else {
            throw JWKSSourceError(reason: "unexpected request: \(url.absoluteString)")
        }
        return try result.get()
    }
}

@Suite("JWKS fetching over HTTP — explicit URL and OIDC discovery (§3.2, §3.3)")
struct HTTPJWKSSourceTests {
    private let identity = TestIdentity(kid: "http-key")
    private let issuer = "https://idp.example.com"
    private let discoveryURL = "https://idp.example.com/.well-known/openid-configuration"
    private let jwksURL = "https://idp.example.com/oauth2/keys"

    private func discoveryDocument(issuer: String, jwksURI: String) -> String {
        #"{"issuer":"\#(issuer)","jwks_uri":"\#(jwksURI)","other_field":true}"#
    }

    private func makeSource(
        jwksURL explicit: URL? = nil, getter: FakeHTTPGetter
    ) -> HTTPJWKSSource {
        HTTPJWKSSource(
            issuer: issuer,
            jwksURL: explicit,
            http: getter,
            logger: Logger(label: "test.jwks")
        )
    }

    @Test("an explicit JWKS URL is fetched directly — no discovery round-trip")
    func explicitURL() async throws {
        let getter = FakeHTTPGetter()
        getter.respond(to: jwksURL, with: jwksJSON([identity]))
        let source = makeSource(jwksURL: URL(string: jwksURL), getter: getter)

        let jwks = try await source.fetchKeys()
        #expect(jwks.keys.count == 1)
        #expect(getter.requested == [jwksURL])
    }

    @Test("without an explicit URL, jwks_uri comes from OIDC discovery (§3.3)")
    func discovery() async throws {
        let getter = FakeHTTPGetter()
        getter.respond(to: discoveryURL, with: discoveryDocument(issuer: issuer, jwksURI: jwksURL))
        getter.respond(to: jwksURL, with: jwksJSON([identity]))
        let source = makeSource(getter: getter)

        let jwks = try await source.fetchKeys()
        #expect(jwks.keys.first?.keyIdentifier?.string == "http-key")
        #expect(getter.requested == [discoveryURL, jwksURL])
    }

    @Test("the discovered jwks_uri is cached — discovery happens once per process")
    func discoveryCached() async throws {
        let getter = FakeHTTPGetter()
        getter.respond(to: discoveryURL, with: discoveryDocument(issuer: issuer, jwksURI: jwksURL))
        getter.respond(to: jwksURL, with: jwksJSON([identity]))
        let source = makeSource(getter: getter)

        _ = try await source.fetchKeys()
        _ = try await source.fetchKeys()
        #expect(getter.requested == [discoveryURL, jwksURL, jwksURL])
    }

    @Test("a trailing slash on the issuer does not double up the discovery path")
    func trailingSlashIssuer() async throws {
        let getter = FakeHTTPGetter()
        getter.respond(to: discoveryURL, with: discoveryDocument(issuer: issuer, jwksURI: jwksURL))
        getter.respond(to: jwksURL, with: jwksJSON([identity]))
        let source = HTTPJWKSSource(
            issuer: issuer + "/", jwksURL: nil, http: getter, logger: Logger(label: "test.jwks")
        )
        _ = try await source.fetchKeys()
        #expect(getter.requested.first == discoveryURL)
    }

    @Test("a discovery document asserting a different issuer is rejected (OIDC Discovery §4.3)")
    func discoveryIssuerMismatch() async throws {
        let getter = FakeHTTPGetter()
        getter.respond(
            to: discoveryURL,
            with: discoveryDocument(issuer: "https://evil.example.com", jwksURI: jwksURL)
        )
        let source = makeSource(getter: getter)

        await #expect(throws: JWKSSourceError.self) {
            _ = try await source.fetchKeys()
        }
        #expect(!getter.requested.contains(jwksURL), "never followed the hostile jwks_uri")
    }

    @Test("a non-HTTP jwks_uri in the discovery document is rejected")
    func nonHTTPJWKSURI() async throws {
        let getter = FakeHTTPGetter()
        getter.respond(
            to: discoveryURL,
            with: discoveryDocument(issuer: issuer, jwksURI: "file:///etc/passwd")
        )
        let source = makeSource(getter: getter)
        await #expect(throws: JWKSSourceError.self) {
            _ = try await source.fetchKeys()
        }
    }

    @Test("a non-URL issuer cannot be discovered against")
    func malformedIssuer() async throws {
        let source = HTTPJWKSSource(
            issuer: "not a url", jwksURL: nil, http: FakeHTTPGetter(),
            logger: Logger(label: "test.jwks")
        )
        await #expect(throws: JWKSSourceError.self) {
            _ = try await source.fetchKeys()
        }
    }

    @Test("HTTP failures and undecodable documents surface as JWKSSourceError")
    func fetchFailures() async throws {
        let failing = FakeHTTPGetter()
        failing.fail(jwksURL, reason: "HTTP 503")
        let source = makeSource(jwksURL: URL(string: jwksURL), getter: failing)
        await #expect(throws: JWKSSourceError.self) {
            _ = try await source.fetchKeys()
        }

        let garbage = FakeHTTPGetter()
        garbage.respond(to: jwksURL, with: "<html>not json</html>")
        let garbageSource = makeSource(jwksURL: URL(string: jwksURL), getter: garbage)
        await #expect(throws: JWKSSourceError.self) {
            _ = try await garbageSource.fetchKeys()
        }
    }
}
