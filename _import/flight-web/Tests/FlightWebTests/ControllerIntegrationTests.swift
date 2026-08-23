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

    func delete(_ id: Int) {
        _ = storage.withLock { $0.removeValue(forKey: id) }
    }

    var count: Int { storage.withLock { $0.count } }
}

/// One instance per request (Flight Core §3, interpreted by Web §2).
@Component(scope: .scoped)
final class RequestTracer: Sendable {
    private static let counter = Mutex(0)
    let id: Int = RequestTracer.counter.withLock { $0 += 1; return $0 }
}

// MARK: - Fixture controller (the design doc's §4 example, fleshed out)

@Controller
struct UserController {
    @Autowired var userService: UserService

    @GetMapping("/users/:id")
    func getUser(_ context: RequestContext) async throws -> User {
        guard let id = context.pathParam("id").flatMap(Int.init) else {
            throw HTTPError(.badRequest, "user id must be an integer")
        }
        guard let user = userService.find(id) else {
            throw HTTPError(.notFound, "no user \(id)")
        }
        return user
    }

    @PostMapping("/users")
    func createUser(_ context: RequestContext, body: CreateUserRequest) async throws -> Response {
        try .json(userService.create(body), status: .created)
    }

    @DeleteMapping("/users/:id")
    func deleteUser(_ context: RequestContext) throws {
        guard let id = context.pathParam("id").flatMap(Int.init) else {
            throw HTTPError(.badRequest, "user id must be an integer")
        }
        userService.delete(id)
    }

    @GetMapping("/users")
    func listUsers(_ context: RequestContext) -> [String: Int] {
        ["count": userService.count]
    }

    @GetMapping("/whoami/:name")
    func whoami(_ context: RequestContext) -> String {
        "you are \(context.pathParam("name") ?? "unknown")"
    }

    @GetMapping("/scoped-pair")
    func scopedPair(_ context: RequestContext) throws -> [String: Int] {
        // Two resolutions inside one request must agree (§2, §3 of Core).
        let first = try context.resolve(RequestTracer.self)
        let second = try context.resolve(RequestTracer.self)
        return ["first": first.id, "second": second.id]
    }

    @GetMapping("/events")
    func events(_ context: RequestContext) -> Response {
        .serverSentEvents { events in
            events.send(data: "one", event: "tick")
            events.send(data: "two", event: "tick")
        }
    }
}

@Controller
struct EchoSocketController {
    @WebSocketMapping("/echo/:room")
    func echo(_ context: RequestContext) throws -> any ConnectionUpgradeHandler {
        EchoHandler(room: context.pathParam("room") ?? "?")
    }
}

struct EchoHandler: ConnectionUpgradeHandler {
    let room: String

    func handle(upgraded connection: UpgradedConnection, context: RequestContext) async throws {
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
    @GetMapping("/side-effect")
    func run(_ context: RequestContext) -> Response {
        SideEffect.ran.withLock { $0 = true }
        return .text("ran")
    }
}

struct SideEffectModule: FlightModule {
    static var dependencies: [any FlightModule.Type] { [UserModule.self] }
    func configure(_ container: Container) throws {
        try SideEffectController._flightRegister(container)
    }
}

// MARK: - Modules

struct UserModule: FlightModule {
    func configure(_ container: Container) throws {
        // The build plugin's flightRegisterAll would make these calls in an
        // app target; tests call the same generated thunks directly.
        try UserService._flightRegister(container)
        try RequestTracer._flightRegister(container)
        try UserController._flightRegister(container)
        try EchoSocketController._flightRegister(container)
    }
}

struct AuthedModule: FlightModule {
    static var dependencies: [any FlightModule.Type] { [UserModule.self] }

    func configure(_ container: Container) throws {
        container.registerMiddleware("auth", order: 10) { context in
            guard context.request.headers[.authorization] != nil else {
                return .respond(.problem(status: .unauthorized, message: "Unauthorized"))
            }
            return .continue
        }
    }
}

// MARK: - Tests

@Suite("Controller end-to-end (§4, §7)", .serialized)
struct ControllerIntegrationTests {

    private func client() throws -> TestClient {
        try TestClient(container: TestContainer.build { UserModule() })
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

    @Test func scopedBeansAreStablePerRequestAndFreshAcrossRequests() async throws {
        let client = try client()
        let first = try await client.get("/scoped-pair").decodeJSON([String: Int].self)
        #expect(first["first"] == first["second"])
        let second = try await client.get("/scoped-pair").decodeJSON([String: Int].self)
        #expect(second["first"] == second["second"])
        #expect(first["first"] != second["first"])
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

    @Test func routesAreVisibleInCoreIntrospection() throws {
        // Routes are components (§4): Core's own introspection lists them.
        let container = try TestContainer.build { UserModule() }
        let routeBeans = container.allRegistrations().filter {
            $0.typeName == String(reflecting: RouteRegistration.self)
        }
        #expect(routeBeans.count == 8)
        #expect(routeBeans.allSatisfy { $0.qualifier != nil })
    }
}

@Suite("Middleware registration & ordering", .serialized)
struct MiddlewareIntegrationTests {

    @Test func middlewareRunsBeforeRouting() async throws {
        let client = try TestClient(container: TestContainer.build { AuthedModule() })
        #expect(await client.get("/users/1").status == .unauthorized)

        var headers = HTTPFields()
        headers[.authorization] = "Bearer ok"
        #expect(await client.get("/users/1", headers: headers).status == .ok)
    }

    @Test func middlewareOrderIsRespected() async throws {
        struct OrderModule: FlightModule {
            func configure(_ container: Container) throws {
                container.registerMiddleware("second", order: 20) { context in
                    .respond(.text((context.pathParam("mark") ?? "") + "second"))
                }
                container.registerMiddleware("first", order: 10) { context in
                    context.pathParameters["mark"] = "first-then-"
                    return .continue
                }
            }
        }
        let client = try TestClient(container: TestContainer.build { OrderModule() })
        let response = await client.get("/anything")
        #expect(response.bodyText == "first-then-second")
    }
}

@Suite("WebSocket via in-memory pair (§6.1)", .serialized)
struct WebSocketIntegrationTests {

    @Test func upgradeRouteEchoes() async throws {
        let client = try TestClient(container: TestContainer.build { UserModule() })
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
        let client = try TestClient(container: TestContainer.build { UserModule() })
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
        let container = try TestContainer.build { SideEffectModule() }
        let dispatch = try DispatchBuilder.build(container: container)

        let request = Request(method: .get, path: "/side-effect")
        #expect(dispatch.acceptsUpgrade(request) == false)
        #expect(SideEffect.ran.withLock { $0 } == false)

        // And the same route still works as ordinary HTTP.
        #expect(await dispatch(request).bodyText == "ran")
        #expect(SideEffect.ran.withLock { $0 } == true)
    }

    @Test("a genuine upgrade route is recognized from the route table alone")
    func upgradeRouteIsRecognized() throws {
        let container = try TestContainer.build { UserModule() }
        let dispatch = try DispatchBuilder.build(container: container)
        #expect(dispatch.acceptsUpgrade(Request(method: .get, path: "/echo/lobby")))
        #expect(!dispatch.acceptsUpgrade(Request(method: .get, path: "/users/1")))
        #expect(!dispatch.acceptsUpgrade(Request(method: .get, path: "/nope")))
    }

    @Test func middlewareGuardsUpgradeRoutes() async throws {
        let client = try TestClient(container: TestContainer.build { AuthedModule() })
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
    @GetMapping("/")
    func index(_ context: RequestContext) -> String { "widget index" }

    @GetMapping("/:id")
    func show(_ context: RequestContext) -> String {
        "widget \(context.pathParam("id") ?? "?")"
    }

    @PostMapping("/")
    func create(_ context: RequestContext) -> Response { .status(.created) }
}

/// A base path ending in "/" must not double the separator with a method
/// path that also starts with "/".
@Controller("/api/v1/gadgets/")
struct GadgetController {
    @GetMapping("/:id")
    func show(_ context: RequestContext) -> String {
        "gadget \(context.pathParam("id") ?? "?")"
    }
}

struct WidgetModule: FlightModule {
    func configure(_ container: Container) throws {
        try WidgetController._flightRegister(container)
        try GadgetController._flightRegister(container)
    }
}

@Suite("@Controller base path (§4 addendum)", .serialized)
struct ControllerBasePathTests {

    private func client() throws -> TestClient {
        try TestClient(container: TestContainer.build { WidgetModule() })
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

    @Test func routesAppearCombinedInCoreIntrospection() throws {
        // Routes are components (§4): the qualifier — and hence introspection —
        // reflects the combined path, not the bare method-level literal.
        let container = try TestContainer.build { WidgetModule() }
        let qualifiers = container.allRegistrations()
            .filter { $0.typeName == String(reflecting: RouteRegistration.self) }
            .compactMap(\.qualifier)
        #expect(qualifiers.contains { $0.hasPrefix("GET /api/v1/widgets/:id @") })
        #expect(qualifiers.contains { $0.hasPrefix("GET /api/v1/widgets @") })
        #expect(!qualifiers.contains { $0.hasPrefix("GET /:id @") })
    }
}
