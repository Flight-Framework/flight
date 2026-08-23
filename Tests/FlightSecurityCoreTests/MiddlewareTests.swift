import FlightCore
import FlightWeb
import FlightWebTesting
import HTTPTypes
import Synchronization
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


/// Runs one middleware layer and reports both what came back and whether the
/// rest of the pipeline was reached.
///
/// The layers here are request-only steps, so under the onion shape
/// "continued" shows up as the terminal having run. `reached` is what the old
/// `case .continue` assertions were really checking.
private func run(
    _ layer: Middleware, _ context: inout RequestContext
) async -> (response: Response, reached: Bool) {
    let reached = Mutex(false)
    let response = await layer(&context) { _ in
        reached.withLock { $0 = true }
        return .status(.noContent)
    }
    return (response, reached.withLock { $0 })
}

@Suite("Authentication middleware and enforcement")
struct MiddlewareTests {
    private func makeContext(authorization: String? = nil) throws -> RequestContext {
        var headers: HTTPFields = [:]
        if let authorization {
            headers[.authorization] = authorization
        }
        let container = try TestContainer.build { StubSecurityModule() }
        return RequestContext.mock(path: "/", headers: headers, container: container)
    }

    @Test("a valid token puts the Principal on the request")
    func validToken() async throws {
        var context = try makeContext(authorization: "Bearer \(StubSecurityModule.token)")
        let result = await run(authenticationMiddleware(), &context)
        guard result.reached else {
            Issue.record("expected the request to continue; it was answered with \(result.response.status)")
            return
        }
        #expect(context.principal?.subject == "stub-user")
        #expect(context.authenticationState.principal != nil)
    }

    @Test("no token continues as anonymous — enforcement is separate")
    func noToken() async throws {
        var context = try makeContext()
        let result = await run(authenticationMiddleware(), &context)
        guard result.reached else {
            Issue.record("expected the request to continue; it was answered with \(result.response.status)")
            return
        }
        #expect(context.principal == nil)
        if case .anonymous = context.authenticationState {} else {
            Issue.record("expected .anonymous")
        }
    }

    @Test("an invalid token continues unauthenticated, with the failure recorded")
    func invalidToken() async throws {
        var context = try makeContext(authorization: "Bearer forged")
        let result = await run(authenticationMiddleware(), &context)
        guard result.reached else {
            Issue.record("expected the request to continue; it was answered with \(result.response.status)")
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
        let result = await run(authenticationMiddleware(), &context)
        guard !result.reached else {
            Issue.record("expected the layer to answer; the request continued instead")
            return
        }
        let response = result.response
        #expect(response.status == .internalServerError)
    }

    @Test("requireAuthentication rejects anonymous requests with a Bearer challenge")
    func requireAuthenticationAnonymous() async throws {
        var context = try makeContext()
        let result = await run(requireAuthentication, &context)
        guard !result.reached else {
            Issue.record("expected the layer to answer; the request continued instead")
            return
        }
        let response = result.response
        #expect(response.status == .unauthorized)
        #expect(response.headers[.wwwAuthenticate] == "Bearer")
    }

    @Test("requireAuthentication distinguishes a rejected credential (RFC 6750) without leaking detail")
    func requireAuthenticationInvalid() async throws {
        var context = try makeContext(authorization: "Bearer forged")
        _ = await run(authenticationMiddleware(), &context)
        let result = await run(requireAuthentication, &context)
        guard !result.reached else {
            Issue.record("expected the layer to answer; the request continued instead")
            return
        }
        let response = result.response
        #expect(response.status == .unauthorized)
        #expect(response.headers[.wwwAuthenticate] == #"Bearer error="invalid_token""#)
        let body = response.bodyData.map { String(decoding: $0, as: UTF8.self) } ?? ""
        #expect(!body.contains("stub"), "no validation detail on the wire")
        #expect(!body.contains("signature"), "no validation detail on the wire")
    }

    @Test("requireAuthentication passes authenticated requests")
    func requireAuthenticationPasses() async throws {
        var context = try makeContext(authorization: "Bearer \(StubSecurityModule.token)")
        _ = await run(authenticationMiddleware(), &context)
        let result = await run(requireAuthentication, &context)
        guard result.reached else {
            Issue.record("expected the request to continue; it was answered with \(result.response.status)")
            return
        }
    }

    @Test("the full chain shape: authenticate, enforce, handle")
    func chainedMiddleware() async throws {
        // Authenticate, then enforce, then the handler — folded the way
        // `DispatchBuilder` folds them.
        let chain: [Middleware] = [authenticationMiddleware(), requireAuthentication]
        let handler: Next = { context in
            .text("hello " + (context.principal?.subject ?? "?"))
        }
        let pipeline = compose(chain, around: handler)

        var authed = try makeContext(authorization: "Bearer \(StubSecurityModule.token)")
        let ok = await pipeline(&authed)
        #expect(ok.status == .ok)
        #expect(ok.bodyText == "hello stub-user")

        var anonymous = try makeContext()
        let denied = await pipeline(&anonymous)
        #expect(denied.status == .unauthorized)
        #expect(denied.headers[.wwwAuthenticate] == "Bearer")
    }

    @Test("withPrincipal binds Principal.current for the operation")
    func withPrincipalBinds() async throws {
        var context = try makeContext(authorization: "Bearer \(StubSecurityModule.token)")
        _ = await run(authenticationMiddleware(), &context)

        let subject = await context.withPrincipal { Principal.current?.subject }
        #expect(subject == "stub-user")
        #expect(Principal.current == nil, "binding unwinds after the operation")

        var anonymous = try makeContext()
        _ = await run(authenticationMiddleware(), &anonymous)
        let none = await anonymous.withPrincipal { Principal.current?.subject }
        #expect(none == nil)
    }

    @Test("handler-level guards: requirePrincipal / requireRole / requireScope")
    func handlerGuards() async throws {
        var context = try makeContext(authorization: "Bearer \(StubSecurityModule.token)")
        _ = await run(authenticationMiddleware(), &context)

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
