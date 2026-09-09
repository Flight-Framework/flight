import FlightCore
import FlightWeb
import FlightWebTesting
import Foundation
import HTTPTypes
import Synchronization
import Testing

// MARK: - Fixture domain

struct User: Codable, Equatable, ResponseEncodable {
    let id: Int
    let name: String
}

struct CreateUserRequest: Codable {
    let name: String
}

@Component
final class UserService: Sendable {
    private let storage = Mutex<[Int: User]>([1: User(id: 1, name: "ada")])

    func find(_ id: Int) -> User? {
        storage.withLock { $0[id] }
    }

    func create(_ request: CreateUserRequest) -> User {
        storage.withLock { users in
            let id = (users.keys.max() ?? 0) + 1
            let user = User(id: id, name: request.name)
            users[id] = user
            return user
        }
    }

    func replace(_ user: User) {
        storage.withLock { $0[user.id] = user }
    }

    func delete(_ id: Int) {
        _ = storage.withLock { $0.removeValue(forKey: id) }
    }

    var count: Int { storage.withLock { $0.count } }
}

/// One instance per request (Flight Core §3, interpreted by Web §2).
@Component
final class RequestTracer: Sendable {
    private static let counter = Mutex(0)
    let id: Int = RequestTracer.counter.withLock { $0 += 1; return $0 }
}

// MARK: - Fixture controller (the design doc's §4 example, fleshed out)

@Controller
struct UserController {
    @Inject var userService: UserService
    @Inject var tracer: RequestTracer

    @GetRoute("/users/:id")
    func getUser(_ context: RequestContext) async throws -> User {
        guard let id = context.pathParam("id").flatMap(Int.init) else {
            throw HTTPError(.badRequest, "user id must be an integer")
        }
        guard let user = userService.find(id) else {
            throw HTTPError(.notFound, "no user \(id)")
        }
        return user
    }

    @PostRoute("/users")
    func createUser(_ context: RequestContext, body: CreateUserRequest) async throws -> Response {
        try .json(userService.create(body), status: .created)
    }

    @DeleteRoute("/users/:id")
    func deleteUser(_ context: RequestContext) throws {
        guard let id = context.pathParam("id").flatMap(Int.init) else {
            throw HTTPError(.badRequest, "user id must be an integer")
        }
        userService.delete(id)
    }

    @PatchRoute("/users/:id")
    func renameUser(_ context: RequestContext, body: CreateUserRequest) async throws -> User {
        guard let id = context.pathParam("id").flatMap(Int.init) else {
            throw HTTPError(.badRequest, "user id must be an integer")
        }
        guard let existing = userService.find(id) else {
            throw HTTPError(.notFound, "no user \(id)")
        }
        let renamed = User(id: existing.id, name: body.name)
        userService.replace(renamed)
        return renamed
    }

    @GetRoute("/users")
    func listUsers(_ context: RequestContext) -> [String: Int] {
        ["count": userService.count]
    }

    @GetRoute("/whoami/:name")
    func whoami(_ context: RequestContext) -> String {
        "you are \(context.pathParam("name") ?? "unknown")"
    }

    @GetRoute("/scoped-pair")
    func scopedPair(_ context: RequestContext) -> [String: Int] {
        // Injected once, so the two reads are the same instance by
        // construction — the identity a per-request resolve used to prove.
        ["first": tracer.id, "second": tracer.id]
    }

    @GetRoute("/events")
    func events(_ context: RequestContext) -> Response {
        .serverSentEvents { events in
            await events.send(data: "one", event: "tick")
            await events.send(data: "two", event: "tick")
        }
    }
}

@Controller
struct EchoSocketController {
    @WebSocketRoute("/echo/:room")
    func echo(_ context: RequestContext) throws -> any WebSocketUpgradeHandler {
        EchoHandler(room: context.pathParam("room") ?? "?")
    }
}

struct EchoHandler: WebSocketUpgradeHandler {
    let room: String

    func handle(upgraded connection: WebSocketConnection, context: RequestContext) async throws {
        try await connection.send("welcome to \(room)")
        for await frame in connection.frames {
            switch frame {
            case .text(let text):
                try await connection.send("echo: \(text)")
            case .close:
                return
            default:
                continue
            }
        }
    }
}

/// Records whether its handler body executed. An upgrade-shaped request at
/// this ordinary HTTP route must leave `ran` false.
enum SideEffect {
    nonisolated(unsafe) static let ran = Mutex(false)
    static func reset() { ran.withLock { $0 = false } }
}

@Controller
struct SideEffectController {
    @GetRoute("/side-effect")
    func run(_ context: RequestContext) -> Response {
        SideEffect.ran.withLock { $0 = true }
        return .text("ran")
    }
}

// MARK: - Route values (what a composition root hands FlightWebModule)

/// UserController + EchoSocketController's routes as values. One shared
/// `UserService` singleton across every route, a fresh `RequestTracer` per
/// request — the identities the container used to arrange, arranged here by
/// the constructing closure instead.
private func userRoutes() -> [RouteRegistration] {
    let userService = UserService()
    let make: @Sendable (RequestContext) throws -> UserController = { _ in
        UserController(userService: userService, tracer: RequestTracer())
    }
    return [
        UserController._flightRoute_getUser_0(make),
        UserController._flightRoute_createUser_1(make),
        UserController._flightRoute_deleteUser_2(make),
        UserController._flightRoute_renameUser_3(make),
        UserController._flightRoute_listUsers_4(make),
        UserController._flightRoute_whoami_5(make),
        UserController._flightRoute_scopedPair_6(make),
        UserController._flightRoute_events_7(make),
        EchoSocketController._flightRoute_echo_0 { _ in EchoSocketController() },
    ]
}

/// Rejects an unauthenticated request before routing — the value form of the
/// old `registerMiddleware("auth")` closure.
struct AuthMiddleware: Middleware {
    func handle(_ context: RequestContext, next: Next) async throws -> Response {
        guard context.request.headers[.authorization] != nil else {
            return .problem(status: .unauthorized, message: "Unauthorized")
        }
        return try await next(context)
    }
}

// MARK: - Tests

@Suite("Controller end-to-end (§4, §7)", .serialized)
struct ControllerIntegrationTests {

    private func client() throws -> TestClient {
        try TestClient(routes: userRoutes())
    }

    @Test func getUserReturnsJSON() async throws {
        let response = try await client().get("/users/1")
        #expect(response.status == .ok)
        #expect(try response.decodeJSON(User.self) == User(id: 1, name: "ada"))
    }

    @Test func getUserReturnsNotFoundForMissingId() async throws {
        // §7's example test, against the real pipeline.
        let response = try await client().get("/users/999")
        #expect(response.status == .notFound)
    }

    @Test func nonIntegerIdIs400() async throws {
        let response = try await client().get("/users/abc")
        #expect(response.status == .badRequest)
    }

    @Test func postDecodesBodyAndAnswers201() async throws {
        let client = try client()
        let response = try await client.post("/users", json: CreateUserRequest(name: "grace"))
        #expect(response.status == .created)
        let created = try response.decodeJSON(User.self)
        #expect(created.name == "grace")
        let fetched = await client.get("/users/\(created.id)")
        #expect(fetched.status == .ok)
    }

    @Test func malformedBodyIs400WithReason() async throws {
        let response = try await client().post("/users", body: Data(#"{"nom":"x"}"#.utf8))
        #expect(response.status == .badRequest)
        #expect(response.bodyText.contains("name"))
    }

    @Test func patchSendsABodyAndReadsTheAnswer() async throws {
        // The verb a partial update uses. TestClient had get/post/put/delete
        // and no patch, so a changeset-backed endpoint could only be reached
        // by hand-building a Request — which is exactly the kind of friction
        // that ends with the PATCH path going untested.
        let client = try client()
        let response = try await client.patch("/users/1", json: CreateUserRequest(name: "ada"))
        #expect(response.status == .ok)
        #expect(try response.decodeJSON(User.self).name == "ada")
        #expect(try await client.get("/users/1").decodeJSON(User.self).name == "ada")
    }

    @Test func voidHandlerAnswers204() async throws {
        let client = try client()
        let response = await client.delete("/users/1")
        #expect(response.status == .noContent)
        #expect(await client.get("/users/1").status == .notFound)
    }

    @Test func dictionaryReturnIsJSON() async throws {
        let response = try await client().get("/users")
        #expect(try response.decodeJSON([String: Int].self)["count"] == 1)
    }

    @Test func stringReturnIsPlainText() async throws {
        let response = try await client().get("/whoami/ada")
        #expect(response.bodyText == "you are ada")
        #expect(response.headers[.contentType]?.contains("text/plain") == true)
    }

    @Test func sseHandlerStreams() async throws {
        let response = try await client().get("/events")
        #expect(response.headers[.contentType]?.contains("text/event-stream") == true)
        let body = String(decoding: await response.collectStreamingBody(), as: UTF8.self)
        #expect(body.contains("data: one"))
        #expect(body.contains("data: two"))
    }

    @Test func unknownRouteIs404() async throws {
        let response = try await client().get("/nope")
        #expect(response.status == .notFound)
    }

    @Test func wrongMethodIs405WithAllow() async throws {
        let response = try await client().put("/users", json: CreateUserRequest(name: "x"))
        #expect(response.status == .methodNotAllowed)
        #expect(response.headers[.allow]?.contains("POST") == true)
    }

    @Test func responsesCarryRequestID() async throws {
        let client = try client()
        let minted = await client.get("/users/1")
        #expect(minted.headers[.xRequestID]?.isEmpty == false)

        var headers = HTTPFields()
        headers[.xRequestID] = "abc-123"
        let honored = await client.get("/users/1", headers: headers)
        #expect(honored.headers[.xRequestID] == "abc-123")
    }

    @Test("every mapped method produces exactly one route value")
    func everyMappingProducesOneRoute() throws {
        // Routes are function calls now (§4): the controller emits one factory
        // per @*Route, and the composition root lists them. Adding a route here
        // means adding a line to `userRoutes()` — a route that appears without
        // anyone noticing is a route nobody meant to publish.
        let routes = userRoutes()
        #expect(routes.count == 9)
        #expect(routes.allSatisfy { !$0.source.isEmpty })
        // Each source names its controller and method — the identity the
        // container qualifier used to carry.
        #expect(routes.contains { $0.source.hasSuffix(".getUser") })
        #expect(routes.contains { $0.source.hasSuffix(".echo") })
    }
}

@Suite("Middleware registration & ordering", .serialized)
struct MiddlewareIntegrationTests {

    @Test func middlewareRunsBeforeRouting() async throws {
        let client = try TestClient(
            routes: userRoutes(),
            middleware: MiddlewareRegistration.lane(.default, [AuthMiddleware()]))
        #expect(await client.get("/users/1").status == .unauthorized)

        var headers = HTTPFields()
        headers[.authorization] = "Bearer ok"
        #expect(await client.get("/users/1", headers: headers).status == .ok)
    }

    @Test func middlewareOrderIsRespected() async throws {
        // First runs outermost, sets a path parameter, and continues; second
        // reads it and answers. Declared order within a lane is preserved.
        struct First: Middleware {
            func handle(_ context: RequestContext, next: Next) async throws -> Response {
                var context = context
                context.pathParameters["mark"] = "first-then-"
                return try await next(context)
            }
        }
        struct Second: Middleware {
            func handle(_ context: RequestContext, next: Next) async throws -> Response {
                .text((context.pathParam("mark") ?? "") + "second")
            }
        }
        let client = try TestClient(
            middleware: MiddlewareRegistration.lane(.default, [First(), Second()]))
        let response = await client.get("/anything")
        #expect(response.bodyText == "first-then-second")
    }
}

@Suite("WebSocket via in-memory pair (§6.1)", .serialized)
struct WebSocketIntegrationTests {

    @Test func upgradeRouteEchoes() async throws {
        let client = try TestClient(routes: userRoutes())
        let socket = try await client.webSocket("/echo/lobby")

        var received: [String] = []
        socket.send("hello")
        for await frame in socket.frames {
            if case .text(let text) = frame {
                received.append(text)
                if received.count == 2 { socket.close() }
            }
            if received.count == 2 { break }
        }
        #expect(received == ["welcome to lobby", "echo: hello"])
        await socket.waitForServer()
    }

    @Test func nonUpgradeRouteRefusesWebSocket() async throws {
        let client = try TestClient(routes: userRoutes())
        await #expect(throws: TestClient.TestClientError.self) {
            _ = try await client.webSocket("/users/1")
        }
    }

    @Test("an upgrade-shaped request never runs an ordinary route's handler")
    func upgradeAtHTTPRouteDoesNotRunHandler() async throws {
        // The refusal above is not enough on its own: it says the client got
        // an error, not that the server stayed still. Dispatching every
        // upgrade-shaped request ran the matched HTTP handler and discarded
        // its response, so any GET route was reachable by anyone willing to
        // attach upgrade headers. The route table now answers first.
        SideEffect.reset()
        let dispatch = try TestClient(
            routes: [SideEffectController._flightRoute_run_0 { _ in SideEffectController() }]
        ).dispatch

        let request = Request(method: .get, path: "/side-effect")
        #expect(dispatch.acceptsUpgrade(request) == false)
        #expect(SideEffect.ran.withLock { $0 } == false)

        // And the same route still works as ordinary HTTP.
        #expect(await dispatch(request).bodyText == "ran")
        #expect(SideEffect.ran.withLock { $0 } == true)
    }

    @Test("a genuine upgrade route is recognized from the route table alone")
    func upgradeRouteIsRecognized() throws {
        let dispatch = try TestClient(routes: userRoutes()).dispatch
        #expect(dispatch.acceptsUpgrade(Request(method: .get, path: "/echo/lobby")))
        #expect(!dispatch.acceptsUpgrade(Request(method: .get, path: "/users/1")))
        #expect(!dispatch.acceptsUpgrade(Request(method: .get, path: "/nope")))
    }

    @Test func middlewareGuardsUpgradeRoutes() async throws {
        let client = try TestClient(
            routes: userRoutes(),
            middleware: MiddlewareRegistration.lane(.default, [AuthMiddleware()]))
        // No Authorization header: the middleware answers 401 before any
        // upgrade happens — exactly the §6.1 "no further middleware" contract
        // in reverse.
        await #expect(throws: TestClient.TestClientError.self) {
            _ = try await client.webSocket("/echo/lobby")
        }
    }
}

// MARK: - @Controller base path (Spring-style combination)

/// A base path plus relative mappings, including the "/" ⇔ base identity
/// and a nested `:` parameter that combines with the base's own path.
@Controller("/api/v1/widgets")
struct WidgetController {
    @GetRoute("/")
    func index(_ context: RequestContext) -> String { "widget index" }

    @GetRoute("/:id")
    func show(_ context: RequestContext) -> String {
        "widget \(context.pathParam("id") ?? "?")"
    }

    @PostRoute("/")
    func create(_ context: RequestContext) -> Response { .status(.created) }
}

/// A base path ending in "/" must not double the separator with a method
/// path that also starts with "/".
@Controller("/api/v1/gadgets/")
struct GadgetController {
    @GetRoute("/:id")
    func show(_ context: RequestContext) -> String {
        "gadget \(context.pathParam("id") ?? "?")"
    }
}

private func widgetRoutes() -> [RouteRegistration] {
    [
        WidgetController._flightRoute_index_0 { _ in WidgetController() },
        WidgetController._flightRoute_show_1 { _ in WidgetController() },
        WidgetController._flightRoute_create_2 { _ in WidgetController() },
        GadgetController._flightRoute_show_0 { _ in GadgetController() },
    ]
}

@Suite("@Controller base path (§4 addendum)", .serialized)
struct ControllerBasePathTests {

    private func client() throws -> TestClient {
        try TestClient(routes: widgetRoutes())
    }

    @Test func rootMappingResolvesToTheBasePathItself() async throws {
        let response = try await client().get("/api/v1/widgets")
        #expect(response.status == .ok)
        #expect(response.bodyText == "widget index")
    }

    @Test func relativeMappingCombinesWithTheBasePath() async throws {
        let response = try await client().get("/api/v1/widgets/42")
        #expect(response.status == .ok)
        #expect(response.bodyText == "widget 42")
    }

    @Test func everyHTTPMethodHonorsTheBasePath() async throws {
        let response = try await client().post("/api/v1/widgets")
        #expect(response.status == .created)
    }

    @Test func unprefixedPathIsNotFound() async throws {
        // The bare relative path is not itself a route — only the combined
        // one is registered.
        let response = try await client().get("/widgets/42")
        #expect(response.status == .notFound)
    }

    @Test func trailingSlashInBasePathDoesNotDoubleTheSeparator() async throws {
        let response = try await client().get("/api/v1/gadgets/7")
        #expect(response.status == .ok)
        #expect(response.bodyText == "gadget 7")
    }

    @Test("the base path is combined into each route's path, not left bare")
    func routesCarryTheCombinedPath() throws {
        // The macro combines base + method path at expansion time; the route
        // value carries the already-combined literal.
        let paths = Set(widgetRoutes().map(\.path))
        #expect(paths.contains("/api/v1/widgets/:id"))
        #expect(paths.contains("/api/v1/widgets"))
        #expect(!paths.contains("/:id"))
    }
}
