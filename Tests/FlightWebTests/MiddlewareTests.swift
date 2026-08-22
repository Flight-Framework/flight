import FlightWeb
import FlightWebTesting
import Foundation
import HTTPTypes
import Testing

@Suite("Middleware pipeline (§3)")
struct MiddlewareTests {

    @Test func chainRunsInOrderAndSharesContext() async {
        let first: Middleware = { context in
            context.pathParameters["trace"] = "first"
            return .continue
        }
        let second: Middleware = { context in
            .respond(.text(context.pathParameters["trace"] ?? "missing"))
        }
        var context = RequestContext.mock(path: "/")
        let response = await runMiddleware([first, second], &context)
        #expect(response.bodyText == "first")
    }

    @Test func respondShortCircuits() async {
        let auth: Middleware = { _ in .respond(.status(.unauthorized)) }
        let mustNotRun: Middleware = { _ in
            Issue.record("middleware after .respond must not run")
            return .continue
        }
        var context = RequestContext.mock(path: "/")
        let response = await runMiddleware([auth, mustNotRun], &context)
        #expect(response.status == .unauthorized)
    }

    @Test func failShortCircuitsThroughErrorResponse() async {
        let failing: Middleware = { _ in .fail(HTTPError(.tooManyRequests, "slow down")) }
        let mustNotRun: Middleware = { _ in
            Issue.record("middleware after .fail must not run")
            return .continue
        }
        var context = RequestContext.mock(path: "/")
        let response = await runMiddleware([failing, mustNotRun], &context)
        #expect(response.status == .tooManyRequests)
        #expect(response.bodyText.contains("slow down"))
    }

    @Test func emptyChainYieldsContextResponse() async {
        var context = RequestContext.mock(path: "/")
        let response = await runMiddleware([], &context)
        #expect(response.status == .notFound)  // the context default
    }

    @Test func authRejectionShape() async {
        // The design doc's own example (§3), verbatim in structure.
        let authMiddleware: Middleware = { context in
            guard context.request.headers[.authorization] != nil else {
                return .respond(.status(.unauthorized))
            }
            return .continue
        }
        var anonymous = RequestContext.mock(path: "/private")
        #expect(await runMiddleware([authMiddleware], &anonymous).status == .unauthorized)

        var headers = HTTPFields()
        headers[.authorization] = "Bearer token"
        var authed = RequestContext.mock(path: "/private", headers: headers)
        authed.response = .noContent
        #expect(await runMiddleware([authMiddleware], &authed).status == .noContent)
    }
}

@Suite("errorResponse (§3)")
struct ErrorResponseTests {

    @Test func httpRepresentableErrorsKeepTheirShape() {
        let response = errorResponse(
            for: HTTPError(.conflict, "already exists"),
            context: .mock(path: "/")
        )
        #expect(response.status == .conflict)
        #expect(response.bodyText.contains("already exists"))
        #expect(response.headers[.contentType]?.contains("application/json") == true)
    }

    @Test func unknownErrorsAreOpaque500s() {
        struct Leaky: Error { let secret = "db password" }
        let response = errorResponse(for: Leaky(), context: .mock(path: "/"))
        #expect(response.status == .internalServerError)
        #expect(!response.bodyText.contains("db password"))
    }

    @Test func routingErrorsAre500WithoutDetailLeaks() {
        let response = errorResponse(
            for: RoutingError.missingPathParameter("id"),
            context: .mock(path: "/")
        )
        #expect(response.status == .internalServerError)
        #expect(!response.bodyText.contains("id"))
    }

    @Test func bodyDecodingErrorsAre400WithReason() {
        let response = errorResponse(
            for: BodyDecodingError("missing key 'name' at top level"),
            context: .mock(path: "/")
        )
        #expect(response.status == .badRequest)
        #expect(response.bodyText.contains("missing key 'name'"))
    }
}

@Suite("Request body decoding")
struct BodyDecodingTests {
    struct CreateUser: Codable, Equatable {
        let name: String
    }

    @Test func decodesValidJSON() throws {
        let context = RequestContext.mock(
            method: .post, path: "/users",
            body: Data(#"{"name":"ada"}"#.utf8)
        )
        let decoded: CreateUser = try decodeRequestBody(from: context)
        #expect(decoded == CreateUser(name: "ada"))
    }

    @Test func emptyBodyIsA400() {
        let context = RequestContext.mock(method: .post, path: "/users")
        #expect(throws: BodyDecodingError.self) {
            let _: CreateUser = try decodeRequestBody(from: context)
        }
    }

    @Test func missingKeyNamesTheKey() {
        let context = RequestContext.mock(
            method: .post, path: "/users",
            body: Data(#"{"nom":"ada"}"#.utf8)
        )
        do {
            let _: CreateUser = try decodeRequestBody(from: context)
            Issue.record("expected decode failure")
        } catch let error as BodyDecodingError {
            #expect(error.httpMessage.contains("name"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }
}
