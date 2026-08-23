import Foundation
import Logging
import Synchronization
import Testing

@testable import FlightSecurityCore

/// Canned responses keyed by URL.
private final class Getter: HTTPGetting, Sendable {
    private let responses = Mutex([String: Data]())
    private let seen = Mutex([String]())

    func respond(to url: String, with body: String) {
        responses.withLock { $0[url] = Data(body.utf8) }
    }
    var requested: [String] { seen.withLock { $0 } }

    func getJSON(_ url: URL) async throws -> Data {
        seen.withLock { $0.append(url.absoluteString) }
        guard let data = responses.withLock({ $0[url.absoluteString] }) else {
            throw JWKSSourceError(reason: "unexpected request: \(url.absoluteString)")
        }
        return data
    }
}

/// The transport that carries key material.
///
/// Every fetch below decides which public keys will verify every token the
/// service accepts. Someone who can answer one of them serves their own
/// signing key and mints any principal they like — so a downgrade to
/// plaintext here is a complete authentication bypass, not a hardening nit.
@Suite("JWKS transport security")
struct TransportSecurityTests {
    private let identity = TestIdentity(kid: "k1")

    private func source(
        issuer: String,
        jwksURL: URL? = nil,
        policy: JWKSTransportPolicy = .httpsOnly,
        getter: Getter
    ) -> HTTPJWKSSource {
        HTTPJWKSSource(
            issuer: issuer, jwksURL: jwksURL, http: getter,
            logger: Logger(label: "test"), policy: policy)
    }

    private func discovery(issuer: String, jwksURI: String) -> String {
        #"{"issuer":"\#(issuer)","jwks_uri":"\#(jwksURI)"}"#
    }

    // MARK: An http:// issuer

    @Test("a plaintext issuer is refused before anything is fetched")
    func plaintextIssuerRefused() async {
        let getter = Getter()
        let source = source(issuer: "http://idp.example.com", getter: getter)
        await #expect(throws: JWKSSourceError.self) { _ = try await source.fetchKeys() }
        #expect(getter.requested.isEmpty, "nothing should have been fetched at all")
    }

    // MARK: A hostile discovery document

    @Test("a discovery document naming an http:// jwks_uri is refused")
    func plaintextJWKSURIRefused() async {
        // The discovery document is remote input. One naming an http://
        // jwks_uri moved the key fetch — the one that decides what verifies
        // tokens — onto a channel anyone on the path can rewrite.
        let getter = Getter()
        let issuer = "https://idp.example.com"
        getter.respond(
            to: "\(issuer)/.well-known/openid-configuration",
            with: discovery(issuer: issuer, jwksURI: "http://idp.example.com/keys"))
        getter.respond(to: "http://idp.example.com/keys", with: jwksJSON([identity]))

        let source = source(issuer: issuer, getter: getter)
        await #expect(throws: JWKSSourceError.self) { _ = try await source.fetchKeys() }
        #expect(
            !getter.requested.contains("http://idp.example.com/keys"),
            "the plaintext key fetch must not have happened")
    }

    // MARK: An explicitly configured URL

    @Test("an explicitly configured http:// jwks_url is refused")
    func plaintextExplicitURLRefused() async {
        // This path skips discovery, and it was the one URL in the package
        // that nothing validated at all.
        let getter = Getter()
        getter.respond(to: "http://idp.example.com/keys", with: jwksJSON([identity]))
        let source = source(
            issuer: "https://idp.example.com",
            jwksURL: URL(string: "http://idp.example.com/keys"),
            getter: getter)

        await #expect(throws: JWKSSourceError.self) { _ = try await source.fetchKeys() }
        #expect(getter.requested.isEmpty)
    }

    // MARK: The deliberate exemptions

    @Test("loopback over http is allowed when asked for, and only loopback")
    func loopbackExemptionIsNarrow() async throws {
        let getter = Getter()
        getter.respond(to: "http://127.0.0.1:8080/keys", with: jwksJSON([identity]))
        let local = source(
            issuer: "https://idp.example.com",
            jwksURL: URL(string: "http://127.0.0.1:8080/keys"),
            policy: .allowInsecureLoopback, getter: getter)
        #expect(try await local.fetchKeys().keys.count == 1)

        // The same policy must not extend to a remote host.
        let remote = source(
            issuer: "https://idp.example.com",
            jwksURL: URL(string: "http://idp.example.com/keys"),
            policy: .allowInsecureLoopback, getter: getter)
        await #expect(throws: JWKSSourceError.self) { _ = try await remote.fetchKeys() }
    }

    @Test("https is always fine")
    func httpsAlwaysAllowed() async throws {
        let getter = Getter()
        let issuer = "https://idp.example.com"
        getter.respond(
            to: "\(issuer)/.well-known/openid-configuration",
            with: discovery(issuer: issuer, jwksURI: "\(issuer)/keys"))
        getter.respond(to: "\(issuer)/keys", with: jwksJSON([identity]))
        #expect(try await source(issuer: issuer, getter: getter).fetchKeys().keys.count == 1)
    }

    // MARK: Policy itself

    @Test("the policy accepts and rejects the expected schemes")
    func policyDecisions() throws {
        func check(_ policy: JWKSTransportPolicy, _ url: String) -> Bool {
            (try? policy.validate(URL(string: url)!, what: "test")) != nil
        }
        #expect(check(.httpsOnly, "https://a.example"))
        #expect(!check(.httpsOnly, "http://a.example"))
        #expect(!check(.httpsOnly, "http://127.0.0.1"))
        #expect(!check(.httpsOnly, "ftp://a.example"))

        #expect(check(.allowInsecureLoopback, "http://127.0.0.1:9000/x"))
        #expect(check(.allowInsecureLoopback, "http://localhost/x"))
        #expect(!check(.allowInsecureLoopback, "http://a.example"))

        #expect(check(.allowInsecureAnywhere, "http://a.example"))
        #expect(!check(.allowInsecureAnywhere, "ftp://a.example"))
    }

    @Test("an unrecognized transport setting fails startup rather than weakening silently")
    func unknownTransportSettingRejected() throws {
        #expect(throws: (any Error).self) {
            _ = try OIDCSecurityConfiguration.transportPolicy("https-only")
        }
        let absent = try OIDCSecurityConfiguration.transportPolicy(nil)
        let explicit = try OIDCSecurityConfiguration.transportPolicy("https_only")
        #expect(absent == .httpsOnly)
        #expect(explicit == .httpsOnly)
    }
}

/// Keys the IdP published for something other than verifying signatures.
@Suite("JWKS key usage filtering")
struct KeyUsageFilteringTests {

    @Test("a key marked use=enc is not added to the verification set")
    func encryptionKeyIgnored() async throws {
        // Every key in the document went into the verification collection
        // regardless of what the IdP said it was for, so a key published for
        // encryption would verify a token signed with its private half.
        let signing = TestIdentity(kid: "sig-key")
        let encryption = TestIdentity(kid: "enc-key")
        let getter = Getter()
        // The fixture already emits "use":"sig"; rewrite that key's own value
        // rather than appending a second one, which JSON would let the decoder
        // resolve either way.
        let marked = jwksJSON([signing, encryption]).replacingOccurrences(
            of: #""use":"sig","alg":"ES256","kid":"enc-key""#,
            with: #""use":"enc","alg":"ES256","kid":"enc-key""#)
        getter.respond(to: "https://idp.example.com/keys", with: marked)

        let source = HTTPJWKSSource(
            issuer: "https://idp.example.com",
            jwksURL: URL(string: "https://idp.example.com/keys"),
            http: getter, logger: Logger(label: "test"))

        let keys = try await source.fetchKeys()
        let kids = keys.keys.compactMap(\.keyIdentifier?.string)
        #expect(kids.contains("sig-key"))
        #expect(!kids.contains("enc-key"), "a key published for encryption must not verify tokens")
    }

    @Test("key_ops without verify is also excluded")
    func keyOpsRespected() async throws {
        let signing = TestIdentity(kid: "a")
        let wrapping = TestIdentity(kid: "b")
        let getter = Getter()
        let marked = jwksJSON([signing, wrapping]).replacingOccurrences(
            of: #""kid":"b""#, with: #""kid":"b","key_ops":["wrapKey","unwrapKey"]"#)
        getter.respond(to: "https://idp.example.com/keys", with: marked)

        let source = HTTPJWKSSource(
            issuer: "https://idp.example.com",
            jwksURL: URL(string: "https://idp.example.com/keys"),
            http: getter, logger: Logger(label: "test"))

        let kids = try await source.fetchKeys().keys.compactMap(\.keyIdentifier?.string)
        #expect(kids == ["a"])
    }

    @Test("use=sig and an absent use are both kept")
    func signingKeysKept() async throws {
        let a = TestIdentity(kid: "a")
        let b = TestIdentity(kid: "b")
        let getter = Getter()
        let marked = jwksJSON([a, b])  // both already carry use=sig
        getter.respond(to: "https://idp.example.com/keys", with: marked)

        let source = HTTPJWKSSource(
            issuer: "https://idp.example.com",
            jwksURL: URL(string: "https://idp.example.com/keys"),
            http: getter, logger: Logger(label: "test"))

        #expect(try await source.fetchKeys().keys.count == 2)
    }
}
