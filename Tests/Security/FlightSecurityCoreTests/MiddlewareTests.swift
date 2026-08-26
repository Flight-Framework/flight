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
    _ layer: any Middleware, _ context: RequestContext
) async throws -> (response: Response, reached: Bool) {
    let reached = Mutex(false)
    let response = try await layer.handle(context) { _ in
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

    /// `Authentication`'s validator is a hard constructor dependency now, not
    /// a per-request lookup — this resolves the same validator
    /// `StubSecurityModule` registered and hands it to the manual
    /// `init(validator:)` the type exists for exactly this case.
    private func authentication(in context: RequestContext) throws -> Authentication {
        Authentication(validator: try context.resolve((any TokenValidator).self))
    }

    @Test("a valid token puts the Principal on the request")
    func validToken() async throws {
        let context = try makeContext(authorization: "Bearer \(StubSecurityModule.token)")
        let result = try await run(authentication(in: context), context)
        guard result.reached else {
            Issue.record("expected the request to continue; it was answered with \(result.response.status)")
            return
        }
        #expect(context.principal?.subject == "stub-user")
        #expect(context.authenticationState.principal != nil)
    }

    @Test("no token continues as anonymous — enforcement is separate")
    func noToken() async throws {
        let context = try makeContext()
        let result = try await run(authentication(in: context), context)
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
        let context = try makeContext(authorization: "Bearer forged")
        let result = try await run(authentication(in: context), context)
        guard result.reached else {
            Issue.record("expected the request to continue; it was answered with \(result.response.status)")
            return
        }
        #expect(context.principal == nil)
        if case .invalidCredential = context.authenticationState {} else {
            Issue.record("expected .invalidCredential")
        }
    }

    @Test("a missing TokenValidator dependency fails at construction, not at request time")
    func missingValidator() throws {
        // Not a per-request 500 any more: @Autowired makes the validator a
        // hard constructor dependency, so an application missing this wiring
        // finds out at freeze() — before its first real request — rather
        // than from whichever request happens to be first to authenticate.
        // That is the improvement migrating this type to @Middleware bought
        // for free.
        #expect(throws: (any Error).self) {
            _ = try Authentication(_flight: TestContainer.empty())
        }
    }

    @Test("requireAuthentication rejects anonymous requests with a Bearer challenge")
    func requireAuthenticationAnonymous() async throws {
        let context = try makeContext()
        let result = try await run(RequireAuthentication(), context)
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
        let context = try makeContext(authorization: "Bearer forged")
        _ = try await run(authentication(in: context), context)
        let result = try await run(RequireAuthentication(), context)
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
        let context = try makeContext(authorization: "Bearer \(StubSecurityModule.token)")
        _ = try await run(authentication(in: context), context)
        let result = try await run(RequireAuthentication(), context)
        guard result.reached else {
            Issue.record("expected the request to continue; it was answered with \(result.response.status)")
            return
        }
    }

    @Test("the full chain shape: authenticate, enforce, handle")
    func chainedMiddleware() async throws {
        // Authenticate, then enforce, then the handler — folded the way
        // `DispatchBuilder` folds them.
        let handler: Next = { context in
            .text("hello " + (context.principal?.subject ?? "?"))
        }

        let authed = try makeContext(authorization: "Bearer \(StubSecurityModule.token)")
        let authedChain = [
            MiddlewareRegistration(try authentication(in: authed)),
            MiddlewareRegistration(RequireAuthentication()),
        ]
        let ok = try await compose(authedChain, around: handler)(authed)
        #expect(ok.status == .ok)
        #expect(ok.bodyText == "hello stub-user")

        let anonymous = try makeContext()
        let anonymousChain = [
            MiddlewareRegistration(try authentication(in: anonymous)),
            MiddlewareRegistration(RequireAuthentication()),
        ]
        let denied = try await compose(anonymousChain, around: handler)(anonymous)
        #expect(denied.status == .unauthorized)
        #expect(denied.headers[.wwwAuthenticate] == "Bearer")
    }

    @Test("withPrincipal binds Principal.current for the operation")
    func withPrincipalBinds() async throws {
        let context = try makeContext(authorization: "Bearer \(StubSecurityModule.token)")
        _ = try await run(authentication(in: context), context)

        let subject = await context.withPrincipal { Principal.current?.subject }
        #expect(subject == "stub-user")
        #expect(Principal.current == nil, "binding unwinds after the operation")

        let anonymous = try makeContext()
        _ = try await run(authentication(in: anonymous), anonymous)
        let none = await anonymous.withPrincipal { Principal.current?.subject }
        #expect(none == nil)
    }

    @Test("handler-level guards: requirePrincipal / requireRole / requireScope")
    func handlerGuards() async throws {
        let context = try makeContext(authorization: "Bearer \(StubSecurityModule.token)")
        _ = try await run(authentication(in: context), context)

        #expect(try context.requirePrincipal().subject == "stub-user")
        #expect(try context.requireRole("admin").subject == "stub-user")

        #expect(throws: SecurityError.forbidden) {
            try context.requireRole("superuser")
        }
        #expect(throws: SecurityError.forbidden) {
            try context.requireScope("read:everything")
        }

        let anonymous = try makeContext()
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
