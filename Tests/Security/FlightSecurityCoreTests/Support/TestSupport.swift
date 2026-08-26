import FlightCore
import FlightWeb
import Foundation
import JWTKit
import Synchronization

@testable import FlightSecurityCore

// MARK: - Fixed clock

/// A settable clock so TTL/cooldown/expiry behavior is tested without
/// sleeping.
final class TestClock: Sendable {
    private let storage: Mutex<Date>

    init(_ start: Date = Date(timeIntervalSince1970: 1_750_000_000)) {
        storage = Mutex(start)
    }

    var now: Date {
        storage.withLock { $0 }
    }

    func advance(by seconds: TimeInterval) {
        storage.withLock { $0 = $0.addingTimeInterval(seconds) }
    }

    var nowProvider: @Sendable () -> Date {
        { self.now }
    }
}

// MARK: - Signing identities

/// A generated ES256 signing identity plus its public JWK form.
struct TestIdentity {
    let kid: String
    let privateKey: ES256PrivateKey

    init(kid: String) {
        self.kid = kid
        self.privateKey = ES256PrivateKey()
    }

    var jwkJSON: String {
        let parameters = privateKey.publicKey.parameters!
        return """
            {"kty":"EC","crv":"P-256","use":"sig","alg":"ES256",\
            "kid":"\(kid)","x":"\(parameters.x)","y":"\(parameters.y)"}
            """
    }

    /// Signs `claims` into a compact JWT with this identity's key and `kid`.
    func sign(_ claims: [String: JSONValue]) async throws -> String {
        let collection = JWTKeyCollection()
        await collection.add(ecdsa: privateKey, kid: JWKIdentifier(string: kid))
        return try await collection.sign(RawClaims(values: claims), kid: JWKIdentifier(string: kid))
    }

    /// Signs with this identity's key but a forged `kid`, for
    /// wrong-key-under-known-kid tests.
    func sign(_ claims: [String: JSONValue], forgingKid forgedKid: String) async throws -> String {
        let collection = JWTKeyCollection()
        await collection.add(ecdsa: privateKey, kid: JWKIdentifier(string: forgedKid))
        return try await collection.sign(RawClaims(values: claims), kid: JWKIdentifier(string: forgedKid))
    }

    /// Signs without any `kid` header (single-key IdP style).
    func signWithoutKid(_ claims: [String: JSONValue]) async throws -> String {
        let collection = JWTKeyCollection()
        await collection.add(ecdsa: privateKey)
        return try await collection.sign(RawClaims(values: claims))
    }
}

func jwksJSON(_ identities: [TestIdentity], extraKeys: [String] = []) -> String {
    let keys = identities.map(\.jwkJSON) + extraKeys
    return #"{"keys":[\#(keys.joined(separator: ","))]}"#
}

func decodeJWKS(_ json: String) throws -> JWKS {
    try JSONDecoder().decode(JWKS.self, from: Data(json.utf8))
}

// MARK: - Standard claims

let testIssuer = "https://idp.example.com"
let testAudience = "my-flight-app"

/// Baseline valid claims relative to `reference`; override/extend per test.
func standardClaims(
    now reference: Date,
    subject: String? = "user-123",
    issuer: String? = testIssuer,
    audience: JSONValue? = .string(testAudience),
    expiresIn: TimeInterval = 3600,
    extra: [String: JSONValue] = [:]
) -> [String: JSONValue] {
    var claims: [String: JSONValue] = [
        "exp": .double(reference.timeIntervalSince1970 + expiresIn),
        "iat": .double(reference.timeIntervalSince1970),
    ]
    if let subject { claims["sub"] = .string(subject) }
    if let issuer { claims["iss"] = .string(issuer) }
    if let audience { claims["aud"] = audience }
    for (key, value) in extra { claims[key] = value }
    return claims
}

// MARK: - In-memory JWKS source

/// A `JWKSSource` with a settable key set, injectable failures, and an
/// optional artificial fetch delay (for single-flight tests).
final class InMemoryJWKSSource: JWKSSource, Sendable {
    private struct State {
        var jwks: JWKS
        var error: (any Error)?
        var fetchCount = 0
    }

    private let state: Mutex<State>
    private let fetchDelay: Duration?

    init(_ jwks: JWKS, fetchDelay: Duration? = nil) {
        state = Mutex(State(jwks: jwks))
        self.fetchDelay = fetchDelay
    }

    convenience init(json: String, fetchDelay: Duration? = nil) throws {
        self.init(try decodeJWKS(json), fetchDelay: fetchDelay)
    }

    var fetchCount: Int {
        state.withLock { $0.fetchCount }
    }

    func setKeys(_ jwks: JWKS) {
        state.withLock {
            $0.jwks = jwks
            $0.error = nil
        }
    }

    func setKeys(json: String) throws {
        setKeys(try decodeJWKS(json))
    }

    func setError(_ error: any Error) {
        state.withLock { $0.error = error }
    }

    func fetchKeys() async throws -> JWKS {
        if let fetchDelay {
            try await Task.sleep(for: fetchDelay)
        }
        return try state.withLock {
            $0.fetchCount += 1
            if let error = $0.error { throw error }
            return $0.jwks
        }
    }
}

// MARK: - Stub validator + modules

/// A `TokenValidator` with canned behavior, keyed by token string.
struct StubValidator: TokenValidator {
    var principalsByToken: [String: Principal] = [:]

    func validate(_ token: String) async throws -> Principal {
        guard let principal = principalsByToken[token] else {
            throw TokenValidationError(kind: .signatureInvalid, reason: "stub: unknown token")
        }
        return principal
    }
}

/// Registers a caller-supplied validator (plus the `PrincipalHolder` scoped
/// bean) — the "custom validator installed before FlightSecurityModule"
/// shape from design
final class CustomValidatorModule: FlightModule {
    static let defaultValidator = Mutex<(any TokenValidator)?>(nil)

    private let validator: any TokenValidator

    convenience init() {
        self.init(validator: Self.defaultValidator.withLock { $0 } ?? StubValidator())
    }

    init(validator: any TokenValidator) {
        self.validator = validator
    }

    func configure(_ container: Container) throws {
        let validator = self.validator
        container.register((any TokenValidator).self, scope: .singleton) { _ in validator }
    }
}

func testPrincipal(
    subject: String = "user-123",
    roles: Set<String> = [],
    scopes: Set<String> = []
) -> Principal {
    Principal(subject: subject, issuer: testIssuer, roles: roles, scopes: scopes)
}

/// `TestContainer.build` never runs the build-time scanner
/// (`flightRegisterAll`) — that is what would ordinarily make
/// `Authentication`, a `@Middleware` type living in FlightSecurityCore,
/// resolvable in a real bootstrapped app with nothing further written for
/// it. Add this alongside `FlightSecurityModule()` in any `TestContainer.build`
/// list that exercises `configure(_:)` end to end (its
/// `container.pipeline { Authentication.self }` call needs something to
/// resolve) — the same reason `MacroIntegrationTests` calls a type's
/// generated `_flightRegister` by hand rather than relying on scanning.
struct MiddlewareScannerStandIn: FlightModule {
    func configure(_ container: Container) throws {
        try Authentication._flightRegister(container)
    }
}
