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
private struct InMemoryOIDCModule: FlightModule {
    /// What `FlightSecurityModule` takes, so the type match finds it.
    let tokenValidator: any TokenValidator

    init(configuration: Configuration, source: InMemoryJWKSSource, clock: TestClock) throws {
        self.tokenValidator = OIDCTokenValidator(
            configuration: try OIDCSecurityConfiguration(configuration: configuration),
            jwksSource: source,
            now: clock.nowProvider
        )
    }

    static var isTypeConstructible: Bool { false }

    init() {
        preconditionFailure("InMemoryOIDCModule must be built with a source and clock")
    }

    func configure(_ container: Container) throws {
        let validator = tokenValidator
        container.register((any TokenValidator).self, scope: .singleton) { _ in validator }
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
        // The canonical security lanes, named exactly as `Docs/web.md` and
        // `PipelineLane`'s own documentation spell them. Nothing here
        // declares them, deliberately: the point of a canonical lane is that
        // an application names it and it works.
        container.registerRoute(
            .get, "/lane/dashboard", source: "RoutesModule", pipelines: [.authenticated]
        ) { context in
            .text(try context.requirePrincipal().subject)
        }
        container.registerRoute(
            .get, "/lane/profile", source: "RoutesModule", pipelines: [.authentication]
        ) { context in
            .text(context.principal?.subject ?? "anonymous")
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
        let oidc = try InMemoryOIDCModule(
            configuration: configuration, source: source, clock: clock)
        let security = FlightSecurityModule(validator: oidc.tokenValidator)
        let container = try TestContainer.build(configuration: configuration) {
            oidc
            security
            RoutesModule()
        }
        // The security middleware is a value the composition root hands to
        // FlightWebModule, so a client that must run it is handed it too.
        return try TestClient(container: container, middleware: security.middleware)
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

    @Test("the .authenticated lane rejects anonymous requests, with no app wiring")
    func authenticatedLane() async throws {
        // `Docs/web.md` documents `pipelines: [.authenticated]` on a
        // controller and never tells you to declare the lane, and the macro
        // warns when a route drops it — so a security module that leaves the
        // lane undeclared turns the documented spelling into an
        // `UndeclaredLaneError` at bootstrap.
        let client = try makeClient()
        let token = try await identity.sign(standardClaims(now: clock.now))

        let allowed = await client.get("/lane/dashboard", headers: bearer(token))
        #expect(allowed.status == .ok)
        #expect(allowed.bodyText == "user-123")

        let denied = await client.get("/lane/dashboard")
        #expect(denied.status == .unauthorized)
        #expect(denied.headers[.wwwAuthenticate] == "Bearer")
    }

    @Test("the .authentication lane establishes identity and rejects nobody")
    func authenticationLane() async throws {
        let client = try makeClient()
        let token = try await identity.sign(standardClaims(now: clock.now))

        #expect(await client.get("/lane/profile", headers: bearer(token)).bodyText == "user-123")

        let anonymous = await client.get("/lane/profile")
        #expect(anonymous.status == .ok)
        #expect(anonymous.bodyText == "anonymous")
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
