import FlightCore
import FlightWeb
import FlightWebTesting
import Foundation
import HTTPTypes
import Testing

@testable import FlightSecurityCore

/// Registers an OIDC validator wired to an in-memory JWKS (real validation
/// path, no network) — standing in for Flight Security OIDC configuring the
/// generic validator. State travels on the instance (TestContainer
/// substitutes provided instances by type), so parallel tests never share
/// key material.
private final class InMemoryOIDCModule: FlightModule {
    private let source: InMemoryJWKSSource?
    private let now: (@Sendable () -> Date)?

    init() {
        source = nil
        now = nil
    }

    init(source: InMemoryJWKSSource, clock: TestClock) {
        self.source = source
        self.now = clock.nowProvider
    }

    func configure(_ container: Container) throws {
        guard let source, let now else {
            fatalError("InMemoryOIDCModule must be instantiated with a source and clock")
        }
        container.register((any TokenValidator).self, scope: .singleton) { c in
            OIDCTokenValidator(
                configuration: try OIDCSecurityConfiguration(
                    configuration: c.resolve(Configuration.self)
                ),
                jwksSource: source,
                now: now
            )
        }
    }
}

/// Application routes exercising the authenticate-then-enforce patterns.
private final class RoutesModule: FlightModule {
    init() {}

    func configure(_ container: Container) throws {
        container.registerRoute(.get, "/public", source: "RoutesModule") { _ in
            .text("public")
        }
        container.registerRoute(.get, "/whoami", source: "RoutesModule") { context in
            let principal = try context.requirePrincipal()
            return .text(principal.subject)
        }
        container.registerRoute(.post, "/admin/users", source: "RoutesModule") { context in
            // The design manual authorization check, verbatim shape.
            guard context.principal?.hasRole("admin") == true else {
                throw SecurityError.forbidden
            }
            return .text("created")
        }
        container.registerRoute(.get, "/documents", source: "RoutesModule") { context in
            //: handler binds the task-local; a "service" reads the
            // ambient principal without it being threaded through.
            try await context.withPrincipal {
                guard let principal = Principal.current else {
                    throw SecurityError.unauthenticated
                }
                return .text("documents of \(principal.subject)")
            }
        }
    }
}

@Suite("End to end through Flight Web's real pipeline")
struct EndToEndTests {
    let clock = TestClock()
    let identity = TestIdentity(kid: "e2e-key")

    private func makeClient() throws -> TestClient {
        let source = try InMemoryJWKSSource(json: jwksJSON([identity]))
        let configuration = Configuration(values: [
            "security.oidc.issuer": testIssuer,
            "security.oidc.audience": testAudience,
        ])
        let container = try TestContainer.build(configuration: configuration) {
            InMemoryOIDCModule(source: source, clock: clock)
            FlightSecurityModule()
            RoutesModule()
        }
        return try TestClient(container: container)
    }

    private func bearer(_ token: String) -> HTTPFields {
        var headers: HTTPFields = [:]
        headers[.authorization] = "Bearer \(token)"
        return headers
    }

    @Test("a signed token authenticates a request through the whole pipeline")
    func authenticatedRoundTrip() async throws {
        let client = try makeClient()
        let token = try await identity.sign(standardClaims(now: clock.now))
        let response = await client.get("/whoami", headers: bearer(token))
        #expect(response.status == .ok)
        #expect(response.bodyText == "user-123")
    }

    @Test("no token: public routes stay public, guarded routes 401")
    func anonymousRequests() async throws {
        let client = try makeClient()
        #expect(await client.get("/public").status == .ok)

        let denied = await client.get("/whoami")
        #expect(denied.status == .unauthorized)
        let body = denied.bodyText
        #expect(!body.lowercased().contains("token"), "generic 401, no detail")
    }

    @Test("a forged token is a generic 401 on guarded routes, anonymous on public ones")
    func forgedToken() async throws {
        let client = try makeClient()
        let forger = TestIdentity(kid: identity.kid)  // same kid, different key
        let forged = try await forger.sign(standardClaims(now: clock.now))

        #expect(await client.get("/public", headers: bearer(forged)).status == .ok)

        let denied = await client.get("/whoami", headers: bearer(forged))
        #expect(denied.status == .unauthorized)
        #expect(!denied.bodyText.lowercased().contains("signature"), "no detail on the wire")
    }

    @Test("an expired token does not authenticate")
    func expiredToken() async throws {
        let client = try makeClient()
        let expired = try await identity.sign(standardClaims(now: clock.now, expiresIn: -7200))
        let response = await client.get("/whoami", headers: bearer(expired))
        #expect(response.status == .unauthorized)
    }

    @Test("manual role authorization in a handler: admin passes, others 403")
    func roleCheck() async throws {
        let client = try makeClient()

        let admin = try await identity.sign(
            standardClaims(now: clock.now, extra: ["roles": .array([.string("admin")])])
        )
        let created = await client.post("/admin/users", headers: bearer(admin))
        #expect(created.status == .ok)

        let user = try await identity.sign(standardClaims(now: clock.now))
        let forbidden = await client.post("/admin/users", headers: bearer(user))
        #expect(forbidden.status == .forbidden)

        let anonymous = await client.post("/admin/users")
        #expect(anonymous.status == .forbidden, "no principal, no role — same generic outcome")
    }

    @Test("withPrincipal carries the identity into service-style code")
    func ambientPrincipal() async throws {
        let client = try makeClient()
        let token = try await identity.sign(standardClaims(now: clock.now))
        let response = await client.get("/documents", headers: bearer(token))
        #expect(response.status == .ok)
        #expect(response.bodyText == "documents of user-123")

        #expect(await client.get("/documents").status == .unauthorized)
    }
}
