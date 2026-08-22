import FlightCore
import FlightWeb
import FlightWebTesting
import HTTPTypes
import Testing

@testable import FlightSecurityCore

/// Registers just the pieces middleware needs, with a stub validator.
private final class StubSecurityModule: FlightModule {
    static let token = "stub-token"

    init() {}

    func configure(_ container: Container) throws {
        container.register(PrincipalHolder.self, scope: .scoped) { _ in PrincipalHolder() }
        let validator = StubValidator(principalsByToken: [
            Self.token: testPrincipal(subject: "stub-user", roles: ["admin"])
        ])
        container.register((any TokenValidator).self, scope: .singleton) { _ in validator }
    }
}

@Suite("Authentication middleware (§4) and enforcement (§5.1)")
struct MiddlewareTests {
    private func makeContext(authorization: String? = nil) throws -> RequestContext {
        var headers: HTTPFields = [:]
        if let authorization {
            headers[.authorization] = authorization
        }
        let container = try TestContainer.build { StubSecurityModule() }
        return RequestContext.mock(path: "/", headers: headers, container: container)
    }

    @Test("a valid token puts the Principal on the request (§4)")
    func validToken() async throws {
        var context = try makeContext(authorization: "Bearer \(StubSecurityModule.token)")
        let result = await authenticationMiddleware()(&context)
        guard case .continue = result else {
            Issue.record("expected .continue, got \(result)")
            return
        }
        #expect(context.principal?.subject == "stub-user")
        #expect(context.authenticationState.principal != nil)
    }

    @Test("no token continues as anonymous — enforcement is separate (§5)")
    func noToken() async throws {
        var context = try makeContext()
        let result = await authenticationMiddleware()(&context)
        guard case .continue = result else {
            Issue.record("expected .continue, got \(result)")
            return
        }
        #expect(context.principal == nil)
        if case .anonymous = context.authenticationState {} else {
            Issue.record("expected .anonymous")
        }
    }

    @Test("an invalid token continues unauthenticated, with the failure recorded (§4)")
    func invalidToken() async throws {
        var context = try makeContext(authorization: "Bearer forged")
        let result = await authenticationMiddleware()(&context)
        guard case .continue = result else {
            Issue.record("expected .continue, got \(result)")
            return
        }
        #expect(context.principal == nil)
        if case .invalidCredential = context.authenticationState {} else {
            Issue.record("expected .invalidCredential")
        }
    }

    @Test("a missing TokenValidator bean fails closed with an opaque 500")
    func missingValidator() async throws {
        var context = RequestContext.mock(
            headers: [.authorization: "Bearer x"], container: TestContainer.empty()
        )
        let result = await authenticationMiddleware()(&context)
        guard case .respond(let response) = result else {
            Issue.record("expected .respond, got \(result)")
            return
        }
        #expect(response.status == .internalServerError)
    }

    @Test("requireAuthentication rejects anonymous requests with a Bearer challenge (§5.1)")
    func requireAuthenticationAnonymous() async throws {
        var context = try makeContext()
        let result = await requireAuthentication(&context)
        guard case .respond(let response) = result else {
            Issue.record("expected .respond, got \(result)")
            return
        }
        #expect(response.status == .unauthorized)
        #expect(response.headers[.wwwAuthenticate] == "Bearer")
    }

    @Test("requireAuthentication distinguishes a rejected credential (RFC 6750) without leaking detail")
    func requireAuthenticationInvalid() async throws {
        var context = try makeContext(authorization: "Bearer forged")
        _ = await authenticationMiddleware()(&context)
        let result = await requireAuthentication(&context)
        guard case .respond(let response) = result else {
            Issue.record("expected .respond, got \(result)")
            return
        }
        #expect(response.status == .unauthorized)
        #expect(response.headers[.wwwAuthenticate] == #"Bearer error="invalid_token""#)
        let body = response.bodyData.map { String(decoding: $0, as: UTF8.self) } ?? ""
        #expect(!body.contains("stub"), "no validation detail on the wire (§3.2)")
        #expect(!body.contains("signature"), "no validation detail on the wire (§3.2)")
    }

    @Test("requireAuthentication passes authenticated requests")
    func requireAuthenticationPasses() async throws {
        var context = try makeContext(authorization: "Bearer \(StubSecurityModule.token)")
        _ = await authenticationMiddleware()(&context)
        let result = await requireAuthentication(&context)
        guard case .continue = result else {
            Issue.record("expected .continue, got \(result)")
            return
        }
    }

    @Test("the full chain shape from the design (§4): authenticate, enforce, handle")
    func chainedMiddleware() async throws {
        let chain: [Middleware] = [
            authenticationMiddleware(),
            requireAuthentication,
            { context in .respond(.text("hello " + (context.principal?.subject ?? "?"))) },
        ]

        var authed = try makeContext(authorization: "Bearer \(StubSecurityModule.token)")
        let ok = await runMiddleware(chain, &authed)
        #expect(ok.status == .ok)

        var anonymous = try makeContext()
        let denied = await runMiddleware(chain, &anonymous)
        #expect(denied.status == .unauthorized)
    }

    @Test("withPrincipal binds Principal.current for the operation (§4)")
    func withPrincipalBinds() async throws {
        var context = try makeContext(authorization: "Bearer \(StubSecurityModule.token)")
        _ = await authenticationMiddleware()(&context)

        let subject = await context.withPrincipal { Principal.current?.subject }
        #expect(subject == "stub-user")
        #expect(Principal.current == nil, "binding unwinds after the operation")

        var anonymous = try makeContext()
        _ = await authenticationMiddleware()(&anonymous)
        let none = await anonymous.withPrincipal { Principal.current?.subject }
        #expect(none == nil)
    }

    @Test("handler-level guards: requirePrincipal / requireRole / requireScope (§5.1)")
    func handlerGuards() async throws {
        var context = try makeContext(authorization: "Bearer \(StubSecurityModule.token)")
        _ = await authenticationMiddleware()(&context)

        #expect(try context.requirePrincipal().subject == "stub-user")
        #expect(try context.requireRole("admin").subject == "stub-user")

        #expect(throws: SecurityError.forbidden) {
            try context.requireRole("superuser")
        }
        #expect(throws: SecurityError.forbidden) {
            try context.requireScope("read:everything")
        }

        var anonymous = try makeContext()
        #expect(throws: SecurityError.unauthenticated) {
            try anonymous.requirePrincipal()
        }
        #expect(throws: SecurityError.unauthenticated) {
            try anonymous.requireRole("admin")
        }
    }

    @Test("SecurityError renders as bare 401/403 with generic messages")
    func securityErrorMapping() {
        #expect(SecurityError.unauthenticated.httpStatus == .unauthorized)
        #expect(SecurityError.forbidden.httpStatus == .forbidden)
        #expect(SecurityError.unauthenticated.httpMessage == "Unauthorized")
        #expect(SecurityError.forbidden.httpMessage == "Forbidden")
    }
}
