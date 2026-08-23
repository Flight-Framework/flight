import FlightWeb
import FlightWebTesting
import Foundation
import HTTPTypes
import Synchronization
import Testing

/// The terminal every pipeline test folds around: answers with whatever the
/// context currently holds, so a chain that never reaches a handler still
/// produces the context's default 404 — the same observable behaviour the flat
/// pipeline had for an empty chain.
private let contextResponder: Next = { context in context.response }

@Suite("Middleware pipeline")
struct MiddlewareTests {

    @Test func chainRunsInOrderAndSharesContext() async {
        let first = middleware(from: { context in
            context.pathParameters["trace"] = "first"
            return .continue
        })
        let second = middleware(from: { context in
            .respond(.text(context.pathParameters["trace"] ?? "missing"))
        })
        var context = RequestContext.mock(path: "/")
        let response = await compose([first, second], around: contextResponder)(&context)
        #expect(response.bodyText == "first")
    }

    @Test func respondShortCircuits() async {
        let auth = middleware(from: { _ in .respond(.status(.unauthorized)) })
        let mustNotRun = middleware(from: { _ in
            Issue.record("middleware after .respond must not run")
            return .continue
        })
        var context = RequestContext.mock(path: "/")
        let response = await compose([auth, mustNotRun], around: contextResponder)(&context)
        #expect(response.status == .unauthorized)
    }

    @Test func failShortCircuitsThroughErrorResponse() async {
        let failing = middleware(from: { _ in .fail(HTTPError(.tooManyRequests, "slow down")) })
        let mustNotRun = middleware(from: { _ in
            Issue.record("middleware after .fail must not run")
            return .continue
        })
        var context = RequestContext.mock(path: "/")
        let response = await compose([failing, mustNotRun], around: contextResponder)(&context)
        #expect(response.status == .tooManyRequests)
        #expect(response.bodyText.contains("slow down"))
    }

    @Test func emptyChainReachesTheResponder() async {
        var context = RequestContext.mock(path: "/")
        let response = await compose([], around: contextResponder)(&context)
        #expect(response.status == .notFound)  // the context default
    }

    @Test func authRejectionShape() async {
        let authMiddleware = middleware(from: { context in
            guard context.request.headers[.authorization] != nil else {
                return .respond(.status(.unauthorized))
            }
            return .continue
        })
        var anonymous = RequestContext.mock(path: "/private")
        #expect(
            await compose([authMiddleware], around: contextResponder)(&anonymous).status
                == .unauthorized)

        var headers = HTTPFields()
        headers[.authorization] = "Bearer token"
        var authed = RequestContext.mock(path: "/private", headers: headers)
        authed.response = .noContent
        #expect(
            await compose([authMiddleware], around: contextResponder)(&authed).status
                == .noContent)
    }
}

/// What the flat pipeline could not do at all: see and change the response.
@Suite("Middleware sees the response")
struct ResponseObservingMiddlewareTests {

    @Test("a layer can read the status the handler produced")
    func readsResponse() async {
        let observed = Mutex<Int?>(nil)
        let logging: Middleware = { context, next in
            let response = await next(&context)
            observed.withLock { $0 = response.status.code }
            return response
        }
        var context = RequestContext.mock(path: "/")
        let responder: Next = { _ in .status(.created) }
        _ = await compose([logging], around: responder)(&context)
        #expect(observed.withLock { $0 } == 201)
    }

    @Test("a layer can add a header on the way out")
    func modifiesResponse() async {
        let cors: Middleware = { context, next in
            await next(&context).settingHeader(.accessControlAllowOrigin, "*")
        }
        var context = RequestContext.mock(path: "/")
        let response = await compose([cors], around: { _ in .noContent })(&context)
        #expect(response.headers[.accessControlAllowOrigin] == "*")
    }

    @Test("outer layers wrap inner ones: in order, out reversed")
    func onionOrdering() async {
        let trace = Mutex<[String]>([])
        func layer(_ name: String) -> Middleware {
            { context, next in
                trace.withLock { $0.append("\(name)-in") }
                let response = await next(&context)
                trace.withLock { $0.append("\(name)-out") }
                return response
            }
        }
        var context = RequestContext.mock(path: "/")
        _ = await compose([layer("a"), layer("b")], around: { _ in
            trace.withLock { $0.append("handler") }
            return .noContent
        })(&context)
        #expect(trace.withLock { $0 } == ["a-in", "b-in", "handler", "b-out", "a-out"])
    }

    @Test("an outer layer still sees the response when an inner one fails")
    func observesErrorResponses() async {
        // The flat pipeline returned from the error path immediately, so
        // access logging would have missed every 500 — the failure mode most
        // worth logging.
        let seen = Mutex<Int?>(nil)
        let logging: Middleware = { context, next in
            let response = await next(&context)
            seen.withLock { $0 = response.status.code }
            return response
        }
        let failing = middleware(from: { _ in .fail(HTTPError(.badGateway, "upstream")) })
        var context = RequestContext.mock(path: "/")
        let response = await compose([logging, failing], around: contextResponder)(&context)
        #expect(response.status == .badGateway)
        #expect(seen.withLock { $0 } == 502)
    }

    @Test("a layer can hold a task local open across the handler")
    func bindsTaskLocalAcrossHandler() async {
        // The capability that decided the design: a scope held open around the
        // handler cannot be expressed as two separate before/after closures.
        enum Tenant { @TaskLocal static var current: String? = nil }
        let scoping: Middleware = { context, next in
            await Tenant.$current.withValue("acme") { await next(&context) }
        }
        var context = RequestContext.mock(path: "/")
        let responder: Next = { _ in .text(Tenant.current ?? "unbound") }
        let response = await compose([scoping], around: responder)(&context)
        #expect(response.bodyText == "acme")
        #expect(Tenant.current == nil, "the binding must not outlive the layer")
    }

    @Test("a layer that never calls next answers alone")
    func skippingNextIsTotal() async {
        // Documented, not desirable: this is the tradeoff the MiddlewareResult
        // form exists to avoid.
        let blocking: Middleware = { _, _ in .status(.serviceUnavailable) }
        var context = RequestContext.mock(path: "/")
        let response = await compose([blocking], around: { _ in
            Issue.record("the responder must not run")
            return .noContent
        })(&context)
        #expect(response.status == .serviceUnavailable)
    }
}

@Suite("errorResponse")
struct ErrorResponseTests {

    @Test func httpRepresentableErrorsKeepTheirShape() throws {
        let response = errorResponse(
            for: HTTPError(.conflict, "already exists"),
            context: .mock(path: "/")
        )
        #expect(response.status == .conflict)
        // RFC 9457: its own media type, not application/json, so a client can
        // tell a problem document from a successful body of the same shape.
        #expect(response.headers[.contentType] == "application/problem+json")

        let body = try JSONSerialization.jsonObject(
            with: Data(response.bodyText.utf8)) as? [String: Any]
        #expect(body?["status"] as? Int == 409)
        #expect(body?["title"] as? String == "Conflict")
        #expect(body?["detail"] as? String == "already exists")
    }

    @Test("the title falls back to the status and detail is omitted when it adds nothing")
    func detailOmittedWhenRedundant() throws {
        let response = errorResponse(for: HTTPError(.notFound, "Not Found"), context: .mock())
        let body = try JSONSerialization.jsonObject(
            with: Data(response.bodyText.utf8)) as? [String: Any]
        #expect(body?["title"] as? String == "Not Found")
        #expect(body?["detail"] == nil, "a detail identical to the title is noise")
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
