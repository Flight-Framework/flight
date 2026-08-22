import FlightWeb
import FlightWebTesting
import Foundation
import HTTPTypes
import Testing

@Suite("RoutePattern")
struct RoutePatternTests {
    @Test func parsesStaticAndParameterSegments() throws {
        let pattern = try RoutePattern("/users/:id/posts")
        #expect(pattern.segments == [.constant("users"), .parameter("id"), .constant("posts")])
    }

    @Test func rejectsMissingLeadingSlash() {
        #expect(throws: RoutePattern.PatternError.mustStartWithSlash("users")) {
            _ = try RoutePattern("users")
        }
    }

    @Test func rejectsEmptyParameterName() {
        #expect(throws: RoutePattern.PatternError.emptyParameterName("/users/:")) {
            _ = try RoutePattern("/users/:")
        }
    }

    @Test func rejectsNonTrailingCatchAll() {
        #expect(throws: RoutePattern.PatternError.catchAllNotTrailing("/files/**/x")) {
            _ = try RoutePattern("/files/**/x")
        }
    }

    @Test func rejectsDuplicateParameterNames() {
        #expect(throws: RoutePattern.PatternError.duplicateParameter("/a/:x/:x", name: "x")) {
            _ = try RoutePattern("/a/:x/:x")
        }
    }

    @Test func shapeIsNameBlind() throws {
        #expect(try RoutePattern("/u/:a").shape == RoutePattern("/u/:b").shape)
        #expect(try RoutePattern("/u/:a").shape != RoutePattern("/u/a").shape)
    }
}

@Suite("Router")
struct RouterTests {
    private func route(
        _ method: HTTPRequest.Method,
        _ path: String,
        kind: RouteRegistration.Kind = .http,
        source: String = "test",
        status: Status = .ok
    ) -> RouteRegistration {
        RouteRegistration(method: method, path: path, kind: kind, source: source) { _ in
            .text(path, status: status)
        }
    }

    @Test func matchesStaticRoute() throws {
        let router = try Router(routes: [route(.get, "/health")])
        guard case .matched(let match) = router.route(method: .get, path: "/health") else {
            Issue.record("expected a match")
            return
        }
        #expect(match.pathParameters.isEmpty)
    }

    @Test func bindsPathParameters() throws {
        let router = try Router(routes: [route(.get, "/users/:id/posts/:postId")])
        guard case .matched(let match) = router.route(method: .get, path: "/users/42/posts/7") else {
            Issue.record("expected a match")
            return
        }
        #expect(match.pathParameters == ["id": "42", "postId": "7"])
    }

    @Test func decodesPercentEncodedParameters() throws {
        let router = try Router(routes: [route(.get, "/users/:name")])
        guard case .matched(let match) = router.route(method: .get, path: "/users/a%20b") else {
            Issue.record("expected a match")
            return
        }
        #expect(match.pathParameters["name"] == "a b")
    }

    @Test func encodedSlashCannotChangeStructure() throws {
        let router = try Router(routes: [route(.get, "/users/:id")])
        // "a%2Fb" decodes to "a/b" but must stay a single segment.
        guard case .matched(let match) = router.route(method: .get, path: "/users/a%2Fb") else {
            Issue.record("expected a match")
            return
        }
        #expect(match.pathParameters["id"] == "a/b")
        // …and it must NOT match a deeper pattern.
        let deep = try Router(routes: [route(.get, "/users/:id/posts")])
        guard case .notFound = deep.route(method: .get, path: "/users/a%2Fposts") else {
            Issue.record("encoded slash changed route structure")
            return
        }
    }

    @Test func staticBeatsParameter() throws {
        let staticRoute = RouteRegistration(method: .get, path: "/users/me", source: "static") { _ in .text("static") }
        let paramRoute = RouteRegistration(method: .get, path: "/users/:id", source: "param") { _ in .text("param") }
        // Declaration order must not matter: param declared first.
        let router = try Router(routes: [paramRoute, staticRoute])
        guard case .matched(let match) = router.route(method: .get, path: "/users/me") else {
            Issue.record("expected a match")
            return
        }
        #expect(match.route.source == "static")
    }

    @Test func catchAllMatchesRemainder() throws {
        let router = try Router(routes: [route(.get, "/files/**")])
        guard case .matched(let match) = router.route(method: .get, path: "/files/a/b/c.txt") else {
            Issue.record("expected a match")
            return
        }
        #expect(match.pathParameters["**"] == "a/b/c.txt")
        // Catch-all requires at least one segment.
        guard case .notFound = router.route(method: .get, path: "/files") else {
            Issue.record("catch-all must not match zero segments")
            return
        }
    }

    @Test func methodNotAllowedListsAllowedMethods() throws {
        let router = try Router(routes: [route(.get, "/users/:id"), route(.delete, "/users/:id")])
        guard case .methodNotAllowed(let allow) = router.route(method: .post, path: "/users/1") else {
            Issue.record("expected methodNotAllowed")
            return
        }
        #expect(Set(allow.map(\.rawValue)) == ["GET", "DELETE", "HEAD"])
    }

    @Test func headFallsBackToGet() throws {
        let router = try Router(routes: [route(.get, "/users/:id")])
        guard case .matched = router.route(method: .head, path: "/users/1") else {
            Issue.record("HEAD should fall back to the GET route")
            return
        }
    }

    @Test func explicitHeadBeatsGetFallback() throws {
        let headRoute = RouteRegistration(method: .head, path: "/thing", source: "head") { _ in .noContent }
        let getRoute = RouteRegistration(method: .get, path: "/thing", source: "get") { _ in .text("get") }
        let router = try Router(routes: [getRoute, headRoute])
        guard case .matched(let match) = router.route(method: .head, path: "/thing") else {
            Issue.record("expected a match")
            return
        }
        #expect(match.route.source == "head")
    }

    @Test func unknownPathIsNotFound() throws {
        let router = try Router(routes: [route(.get, "/users")])
        guard case .notFound = router.route(method: .get, path: "/nope") else {
            Issue.record("expected notFound")
            return
        }
    }

    @Test func conflictingShapesAreAStartupError() {
        let a = RouteRegistration(method: .get, path: "/u/:a", source: "ControllerA.one") { _ in .noContent }
        let b = RouteRegistration(method: .get, path: "/u/:b", source: "ControllerB.two") { _ in .noContent }
        #expect(throws: RouterError.self) {
            _ = try Router(routes: [a, b])
        }
    }

    @Test func sameShapeDifferentMethodsCoexist() throws {
        let router = try Router(routes: [route(.get, "/u/:id"), route(.put, "/u/:id")])
        #expect(router.routes.count == 2)
    }

    @Test func invalidPatternNamesItsSource() {
        let bad = RouteRegistration(method: .get, path: "no-slash", source: "BadController.method") { _ in .noContent }
        do {
            _ = try Router(routes: [bad])
            Issue.record("expected an error")
        } catch let error as RouterError {
            #expect(String(describing: error).contains("BadController.method"))
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test func trailingSlashIsEquivalentToBare() throws {
        // split(omittingEmptySubsequences:) canonicalizes "/users/" == "/users".
        let router = try Router(routes: [route(.get, "/users")])
        guard case .matched = router.route(method: .get, path: "/users/") else {
            Issue.record("expected a match for trailing slash")
            return
        }
    }
}

@Suite("Routing middleware")
struct RoutingMiddlewareTests {
    @Test func matchedRouteRespondsAndBindsParameters() async throws {
        let registration = RouteRegistration(method: .get, path: "/users/:id", source: "t") { context in
            .text("user \(context.pathParam("id") ?? "?")")
        }
        let router = try Router(routes: [registration])
        var context = RequestContext.mock(path: "/users/9")
        let response = await runMiddleware([router.middleware], &context)
        #expect(response.status == .ok)
        #expect(response.bodyText == "user 9")
    }

    @Test func noMatchIs404() async throws {
        let router = try Router(routes: [])
        var context = RequestContext.mock(path: "/users/999")
        let response = await runMiddleware([router.middleware], &context)
        #expect(response.status == .notFound)
    }

    @Test func methodNotAllowedCarriesAllowHeader() async throws {
        let router = try Router(routes: [
            RouteRegistration(method: .post, path: "/only-post", source: "t") { _ in .noContent }
        ])
        var context = RequestContext.mock(method: .get, path: "/only-post")
        let response = await runMiddleware([router.middleware], &context)
        #expect(response.status == .methodNotAllowed)
        #expect(response.headers[.allow] == "POST")
    }

    @Test func thrownHandlerErrorsBecomeErrorResponses() async throws {
        let router = try Router(routes: [
            RouteRegistration(method: .get, path: "/boom", source: "t") { _ in
                throw HTTPError(.forbidden, "no entry")
            }
        ])
        var context = RequestContext.mock(path: "/boom")
        let response = await runMiddleware([router.middleware], &context)
        #expect(response.status == .forbidden)
        #expect(response.bodyText.contains("no entry"))
    }
}
