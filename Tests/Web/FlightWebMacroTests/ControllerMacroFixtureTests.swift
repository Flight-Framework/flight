// Flight Web §4 — controller macro expansions, pinned as fixtures.
//
// Same discipline as FlightCoreMacroTests: these expected strings are the
// normative expansion spec; the design doc's prose examples are
// illustrative. The runtime integration suite (FlightWebTests) proves the
// compiled path end-to-end; these pin the generated *shape*.

import SwiftSyntax
import SwiftSyntaxMacroExpansion
import SwiftSyntaxMacros
import SwiftSyntaxMacrosGenericTestSupport
import Testing

@testable import FlightWebMacrosImpl

private let testMacros: [String: MacroSpec] = [
    "Controller": MacroSpec(type: ControllerMacro.self, conformances: ["FlightCore._FlightRegistrable"]),
    "GetRoute": MacroSpec(type: RouteMacro.self),
    "PostRoute": MacroSpec(type: RouteMacro.self),
    "DeleteRoute": MacroSpec(type: RouteMacro.self),
    "WebSocketRoute": MacroSpec(type: RouteMacro.self),
]

@Suite("controller macro fixture tests")
struct ControllerMacroFixtureTests {

    // MARK: Fixture 1 — plain GET handler with a return value

    @Test("get handler expansion")
    func getHandlerExpansion() {
        assertMacroExpansion(
            """
            @Controller
            struct HealthController {
                @GetRoute("/health")
                func health(_ context: RequestContext) async throws -> String {
                    "ok"
                }
            }
            """,
            expandedSource: """
            struct HealthController {
                func health(_ context: RequestContext) async throws -> String {
                    "ok"
                }

                internal init(_flight container: FlightCore.Container) throws {
                }

                init() {
                }

                static func _flightRoute_health_0(_ make: @escaping @Sendable (FlightWeb.RequestContext) throws -> Self) -> FlightWeb.RouteRegistration {
                    FlightWeb.RouteRegistration(method: "GET", path: "/health", kind: .http, source: String(reflecting: Self.self) + ".health") { context in
                        let controller = try make(context)
                        let result = try await controller.health(context)
                        return try FlightWeb.encodeResponse(result, for: context)
                    }
                }

                static func _flightRegister(_ container: FlightCore.Container) throws {
                    try _flightRegister(container, includingRoutes: true)
                }

                static func _flightRegister(_ container: FlightCore.Container, includingRoutes: Bool) throws {
                    container.register(Self.self, scope: .singleton, stereotype: .controller) { c in
                        try Self(_flight: c)
                    }
                    guard includingRoutes else {
                        return
                    }
                    container.register(FlightWeb.RouteRegistration.self, qualifier: "GET /health @" + String(reflecting: Self.self) + ".health", scope: .singleton) { c in
                        let controller = try c.resolve(Self.self)
                        return Self._flightRoute_health_0 { _ in
                            controller
                        }
                    }
                }
            }

            extension HealthController: FlightCore._FlightRegistrable {
            }
            """,
            macroSpecs: testMacros
        )
    }

    // MARK: Fixture 2 — body-decoding POST + @Inject + Void DELETE

    @Test("body and void handlers")
    func bodyAndVoidHandlers() {
        assertMacroExpansion(
            """
            @Controller
            public struct UserController {
                @Inject var userService: UserService

                @PostRoute("/users")
                func createUser(_ context: RequestContext, body: CreateUserRequest) async throws -> UserResponse {
                    try await userService.create(body)
                }

                @DeleteRoute("/users/:id")
                func deleteUser(_ context: RequestContext) throws {
                    try userService.delete(context.pathParam("id"))
                }
            }
            """,
            expandedSource: """
            public struct UserController {
                @Inject var userService: UserService
                func createUser(_ context: RequestContext, body: CreateUserRequest) async throws -> UserResponse {
                    try await userService.create(body)
                }
                func deleteUser(_ context: RequestContext) throws {
                    try userService.delete(context.pathParam("id"))
                }

                internal init(_flight container: FlightCore.Container) throws {
                    self.userService = try container.resolve(UserService.self)
                }

                public init(userService: UserService) {
                    self.userService = userService
                }

                static func _flightRoute_createUser_0(_ make: @escaping @Sendable (FlightWeb.RequestContext) throws -> Self) -> FlightWeb.RouteRegistration {
                    FlightWeb.RouteRegistration(method: "POST", path: "/users", kind: .http, source: String(reflecting: Self.self) + ".createUser") { context in
                        let controller = try make(context)
                        let body = try FlightWeb.decodeRequestBody(CreateUserRequest.self, from: context)
                        let result = try await controller.createUser(context, body: body)
                        return try FlightWeb.encodeResponse(result, for: context)
                    }
                }

                static func _flightRoute_deleteUser_1(_ make: @escaping @Sendable (FlightWeb.RequestContext) throws -> Self) -> FlightWeb.RouteRegistration {
                    FlightWeb.RouteRegistration(method: "DELETE", path: "/users/:id", kind: .http, source: String(reflecting: Self.self) + ".deleteUser") { context in
                        let controller = try make(context)
                        try controller.deleteUser(context)
                        return FlightWeb.Response.noContent
                    }
                }

                public static func _flightRegister(_ container: FlightCore.Container) throws {
                    try _flightRegister(container, includingRoutes: true)
                }

                public static func _flightRegister(_ container: FlightCore.Container, includingRoutes: Bool) throws {
                    container.register(Self.self, scope: .singleton, stereotype: .controller) { c in
                        try Self(_flight: c)
                    }
                    guard includingRoutes else {
                        return
                    }
                    container.register(FlightWeb.RouteRegistration.self, qualifier: "POST /users @" + String(reflecting: Self.self) + ".createUser", scope: .singleton) { c in
                        let controller = try c.resolve(Self.self)
                        return Self._flightRoute_createUser_0 { _ in
                            controller
                        }
                    }
                    container.register(FlightWeb.RouteRegistration.self, qualifier: "DELETE /users/:id @" + String(reflecting: Self.self) + ".deleteUser", scope: .singleton) { c in
                        let controller = try c.resolve(Self.self)
                        return Self._flightRoute_deleteUser_1 { _ in
                            controller
                        }
                    }
                }
            }

            extension UserController: FlightCore._FlightRegistrable {
            }
            """,
            macroSpecs: testMacros
        )
    }

    // MARK: Fixture 3 — WebSocket mapping (§6.1)

    @Test("web socket mapping expansion")
    func webSocketMappingExpansion() {
        assertMacroExpansion(
            """
            @Controller
            struct ChatController {
                @WebSocketRoute("/chat/:roomId")
                func chat(_ context: RequestContext) async throws -> any WebSocketUpgradeHandler {
                    ChatRoomHandler(roomId: context.pathParam("roomId")!)
                }
            }
            """,
            expandedSource: """
            struct ChatController {
                func chat(_ context: RequestContext) async throws -> any WebSocketUpgradeHandler {
                    ChatRoomHandler(roomId: context.pathParam("roomId")!)
                }

                internal init(_flight container: FlightCore.Container) throws {
                }

                init() {
                }

                static func _flightRoute_chat_0(_ make: @escaping @Sendable (FlightWeb.RequestContext) throws -> Self) -> FlightWeb.RouteRegistration {
                    FlightWeb.RouteRegistration(method: "GET", path: "/chat/:roomId", kind: .upgrade(.webSocket), source: String(reflecting: Self.self) + ".chat") { context in
                        let controller = try make(context)
                        let upgradeHandler = try await controller.chat(context)
                        return FlightWeb.Response.upgrade(handler: upgradeHandler, context: context)
                    }
                }

                static func _flightRegister(_ container: FlightCore.Container) throws {
                    try _flightRegister(container, includingRoutes: true)
                }

                static func _flightRegister(_ container: FlightCore.Container, includingRoutes: Bool) throws {
                    container.register(Self.self, scope: .singleton, stereotype: .controller) { c in
                        try Self(_flight: c)
                    }
                    guard includingRoutes else {
                        return
                    }
                    container.register(FlightWeb.RouteRegistration.self, qualifier: "GET /chat/:roomId @" + String(reflecting: Self.self) + ".chat", scope: .singleton) { c in
                        let controller = try c.resolve(Self.self)
                        return Self._flightRoute_chat_0 { _ in
                            controller
                        }
                    }
                }
            }

            extension ChatController: FlightCore._FlightRegistrable {
            }
            """,
            macroSpecs: testMacros
        )
    }

    // MARK: Diagnostics — every misuse names the fix at the site

    @Test("non literal path is an error")
    func nonLiteralPathIsAnError() {
        assertMacroExpansion(
            """
            @Controller
            struct BadController {
                @GetRoute(somePath)
                func handler(_ context: RequestContext) -> String { "x" }
            }
            """,
            expandedSource: """
            struct BadController {
                func handler(_ context: RequestContext) -> String { "x" }

                internal init(_flight container: FlightCore.Container) throws {
                }

                init() {
                }

                static func _flightRegister(_ container: FlightCore.Container) throws {
                    try _flightRegister(container, includingRoutes: true)
                }

                static func _flightRegister(_ container: FlightCore.Container, includingRoutes: Bool) throws {
                    container.register(Self.self, scope: .singleton, stereotype: .controller) { c in
                        try Self(_flight: c)
                    }
                }
            }

            extension BadController: FlightCore._FlightRegistrable {
            }
            """,
            diagnostics: [
                // Once. It used to be twice — @Controller's scan and the peer
                // marker both validated, at the identical line and column.
                DiagnosticSpec(
                    message: "@GetRoute requires a string-literal path — the route table is built at compile time (§4).",
                    line: 3, column: 5
                )
            ],
            macroSpecs: testMacros
        )
    }

    @Test("static handler is an error")
    func staticHandlerIsAnError() {
        assertMacroExpansion(
            """
            @Controller
            struct BadController {
                @GetRoute("/x")
                static func handler(_ context: RequestContext) -> String { "x" }
            }
            """,
            expandedSource: """
            struct BadController {
                static func handler(_ context: RequestContext) -> String { "x" }

                internal init(_flight container: FlightCore.Container) throws {
                }

                init() {
                }

                static func _flightRegister(_ container: FlightCore.Container) throws {
                    try _flightRegister(container, includingRoutes: true)
                }

                static func _flightRegister(_ container: FlightCore.Container, includingRoutes: Bool) throws {
                    container.register(Self.self, scope: .singleton, stereotype: .controller) { c in
                        try Self(_flight: c)
                    }
                }
            }

            extension BadController: FlightCore._FlightRegistrable {
            }
            """,
            diagnostics: [
                // Once. It used to be twice — the peer marker validated the
                // same method @Controller's scan already had.
                DiagnosticSpec(
                    message: "Route handler 'handler' must be an instance method — the container resolves the controller instance per registration.",
                    line: 3, column: 5
                )
            ],
            macroSpecs: testMacros
        )
    }

    @Test("missing context parameter is an error")
    func missingContextParameterIsAnError() {
        assertMacroExpansion(
            """
            @Controller
            struct BadController {
                @GetRoute("/x")
                func handler() -> String { "x" }
            }
            """,
            expandedSource: """
            struct BadController {
                func handler() -> String { "x" }

                internal init(_flight container: FlightCore.Container) throws {
                }

                init() {
                }

                static func _flightRegister(_ container: FlightCore.Container) throws {
                    try _flightRegister(container, includingRoutes: true)
                }

                static func _flightRegister(_ container: FlightCore.Container, includingRoutes: Bool) throws {
                    container.register(Self.self, scope: .singleton, stereotype: .controller) { c in
                        try Self(_flight: c)
                    }
                }
            }

            extension BadController: FlightCore._FlightRegistrable {
            }
            """,
            diagnostics: [
                // Once. It used to be twice — the peer marker validated the
                // same method @Controller's scan already had.
                DiagnosticSpec(
                    message: "Route handler 'handler' must take '_ context: RequestContext' as its first parameter.",
                    line: 3, column: 5
                )
            ],
            macroSpecs: testMacros
        )
    }

    @Test("duplicate routes in one controller are an error")
    func duplicateRoutesInOneControllerAreAnError() {
        assertMacroExpansion(
            """
            @Controller
            struct BadController {
                @GetRoute("/same")
                func one(_ context: RequestContext) -> String { "1" }
                @GetRoute("/same")
                func two(_ context: RequestContext) -> String { "2" }
            }
            """,
            expandedSource: """
            struct BadController {
                func one(_ context: RequestContext) -> String { "1" }
                func two(_ context: RequestContext) -> String { "2" }
            }

            extension BadController: FlightCore._FlightRegistrable {
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "Route 'GET /same' is declared by both 'one' and 'two' in this controller.",
                    line: 5, column: 5
                )
            ],
            macroSpecs: testMacros
        )
    }

    @Test("non final class controller is an error")
    func nonFinalClassControllerIsAnError() {
        assertMacroExpansion(
            """
            @Controller
            class OpenController {
            }
            """,
            expandedSource: """
            class OpenController {
            }

            extension OpenController: FlightCore._FlightRegistrable {
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@Controller requires a final class (or a struct). Mark 'OpenController' final.",
                    line: 2, column: 7
                )
            ],
            macroSpecs: testMacros
        )
    }

    @Test("invalid path pattern is an error")
    func invalidPathPatternIsAnError() {
        assertMacroExpansion(
            """
            @Controller
            struct BadController {
                @GetRoute("users")
                func handler(_ context: RequestContext) -> String { "x" }
            }
            """,
            expandedSource: """
            struct BadController {
                func handler(_ context: RequestContext) -> String { "x" }

                internal init(_flight container: FlightCore.Container) throws {
                }

                init() {
                }

                static func _flightRoute_handler_0(_ make: @escaping @Sendable (FlightWeb.RequestContext) throws -> Self) -> FlightWeb.RouteRegistration {
                    FlightWeb.RouteRegistration(method: "GET", path: "users", kind: .http, source: String(reflecting: Self.self) + ".handler") { context in
                        let controller = try make(context)
                        let result = controller.handler(context)
                        return try FlightWeb.encodeResponse(result, for: context)
                    }
                }

                static func _flightRegister(_ container: FlightCore.Container) throws {
                    try _flightRegister(container, includingRoutes: true)
                }

                static func _flightRegister(_ container: FlightCore.Container, includingRoutes: Bool) throws {
                    container.register(Self.self, scope: .singleton, stereotype: .controller) { c in
                        try Self(_flight: c)
                    }
                    guard includingRoutes else {
                        return
                    }
                    container.register(FlightWeb.RouteRegistration.self, qualifier: "GET users @" + String(reflecting: Self.self) + ".handler", scope: .singleton) { c in
                        let controller = try c.resolve(Self.self)
                        return Self._flightRoute_handler_0 { _ in
                            controller
                        }
                    }
                }
            }

            extension BadController: FlightCore._FlightRegistrable {
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@GetRoute path 'users' must start with '/'.",
                    line: 3, column: 5
                )
            ],
            macroSpecs: testMacros
        )
    }

    // MARK: Fixture 4 — @Controller base path, Spring-style combination

    @Test("controller base path combines with method paths")
    func controllerBasePathCombinesWithMethodPaths() {
        assertMacroExpansion(
            """
            @Controller("/users")
            struct UserController {
                @GetRoute("/")
                func index(_ context: RequestContext) -> String { "x" }

                @GetRoute("/:id")
                func show(_ context: RequestContext) -> String { "x" }
            }
            """,
            expandedSource: """
            struct UserController {
                func index(_ context: RequestContext) -> String { "x" }
                func show(_ context: RequestContext) -> String { "x" }

                internal init(_flight container: FlightCore.Container) throws {
                }

                init() {
                }

                static func _flightRoute_index_0(_ make: @escaping @Sendable (FlightWeb.RequestContext) throws -> Self) -> FlightWeb.RouteRegistration {
                    FlightWeb.RouteRegistration(method: "GET", path: "/users", kind: .http, source: String(reflecting: Self.self) + ".index") { context in
                        let controller = try make(context)
                        let result = controller.index(context)
                        return try FlightWeb.encodeResponse(result, for: context)
                    }
                }

                static func _flightRoute_show_1(_ make: @escaping @Sendable (FlightWeb.RequestContext) throws -> Self) -> FlightWeb.RouteRegistration {
                    FlightWeb.RouteRegistration(method: "GET", path: "/users/:id", kind: .http, source: String(reflecting: Self.self) + ".show") { context in
                        let controller = try make(context)
                        let result = controller.show(context)
                        return try FlightWeb.encodeResponse(result, for: context)
                    }
                }

                static func _flightRegister(_ container: FlightCore.Container) throws {
                    try _flightRegister(container, includingRoutes: true)
                }

                static func _flightRegister(_ container: FlightCore.Container, includingRoutes: Bool) throws {
                    container.register(Self.self, scope: .singleton, stereotype: .controller) { c in
                        try Self(_flight: c)
                    }
                    guard includingRoutes else {
                        return
                    }
                    container.register(FlightWeb.RouteRegistration.self, qualifier: "GET /users @" + String(reflecting: Self.self) + ".index", scope: .singleton) { c in
                        let controller = try c.resolve(Self.self)
                        return Self._flightRoute_index_0 { _ in
                            controller
                        }
                    }
                    container.register(FlightWeb.RouteRegistration.self, qualifier: "GET /users/:id @" + String(reflecting: Self.self) + ".show", scope: .singleton) { c in
                        let controller = try c.resolve(Self.self)
                        return Self._flightRoute_show_1 { _ in
                            controller
                        }
                    }
                }
            }

            extension UserController: FlightCore._FlightRegistrable {
            }
            """,
            macroSpecs: testMacros
        )
    }

    /// A base path ending in "/" must not double the separator at the seam.
    @Test("controller base path trailing slash collapses")
    func controllerBasePathTrailingSlashCollapses() {
        assertMacroExpansion(
            """
            @Controller("/users/")
            struct UserController {
                @GetRoute("/:id")
                func show(_ context: RequestContext) -> String { "x" }
            }
            """,
            expandedSource: """
            struct UserController {
                func show(_ context: RequestContext) -> String { "x" }

                internal init(_flight container: FlightCore.Container) throws {
                }

                init() {
                }

                static func _flightRoute_show_0(_ make: @escaping @Sendable (FlightWeb.RequestContext) throws -> Self) -> FlightWeb.RouteRegistration {
                    FlightWeb.RouteRegistration(method: "GET", path: "/users/:id", kind: .http, source: String(reflecting: Self.self) + ".show") { context in
                        let controller = try make(context)
                        let result = controller.show(context)
                        return try FlightWeb.encodeResponse(result, for: context)
                    }
                }

                static func _flightRegister(_ container: FlightCore.Container) throws {
                    try _flightRegister(container, includingRoutes: true)
                }

                static func _flightRegister(_ container: FlightCore.Container, includingRoutes: Bool) throws {
                    container.register(Self.self, scope: .singleton, stereotype: .controller) { c in
                        try Self(_flight: c)
                    }
                    guard includingRoutes else {
                        return
                    }
                    container.register(FlightWeb.RouteRegistration.self, qualifier: "GET /users/:id @" + String(reflecting: Self.self) + ".show", scope: .singleton) { c in
                        let controller = try c.resolve(Self.self)
                        return Self._flightRoute_show_0 { _ in
                            controller
                        }
                    }
                }
            }

            extension UserController: FlightCore._FlightRegistrable {
            }
            """,
            macroSpecs: testMacros
        )
    }

    /// Omitted base path is the identity: existing @Controller types are
    /// unaffected (backward compatibility, checked explicitly).
    @Test("omitted controller path is unprefixed")
    func omittedControllerPathIsUnprefixed() {
        assertMacroExpansion(
            """
            @Controller
            struct HealthController {
                @GetRoute("/health")
                func health(_ context: RequestContext) -> String { "ok" }
            }
            """,
            expandedSource: """
            struct HealthController {
                func health(_ context: RequestContext) -> String { "ok" }

                internal init(_flight container: FlightCore.Container) throws {
                }

                init() {
                }

                static func _flightRoute_health_0(_ make: @escaping @Sendable (FlightWeb.RequestContext) throws -> Self) -> FlightWeb.RouteRegistration {
                    FlightWeb.RouteRegistration(method: "GET", path: "/health", kind: .http, source: String(reflecting: Self.self) + ".health") { context in
                        let controller = try make(context)
                        let result = controller.health(context)
                        return try FlightWeb.encodeResponse(result, for: context)
                    }
                }

                static func _flightRegister(_ container: FlightCore.Container) throws {
                    try _flightRegister(container, includingRoutes: true)
                }

                static func _flightRegister(_ container: FlightCore.Container, includingRoutes: Bool) throws {
                    container.register(Self.self, scope: .singleton, stereotype: .controller) { c in
                        try Self(_flight: c)
                    }
                    guard includingRoutes else {
                        return
                    }
                    container.register(FlightWeb.RouteRegistration.self, qualifier: "GET /health @" + String(reflecting: Self.self) + ".health", scope: .singleton) { c in
                        let controller = try c.resolve(Self.self)
                        return Self._flightRoute_health_0 { _ in
                            controller
                        }
                    }
                }
            }

            extension HealthController: FlightCore._FlightRegistrable {
            }
            """,
            macroSpecs: testMacros
        )
    }

    @Test("controller path must start with slash")
    func controllerPathMustStartWithSlash() {
        assertMacroExpansion(
            """
            @Controller("users")
            struct BadController {
                @GetRoute("/:id")
                func show(_ context: RequestContext) -> String { "x" }
            }
            """,
            expandedSource: """
            struct BadController {
                func show(_ context: RequestContext) -> String { "x" }

                internal init(_flight container: FlightCore.Container) throws {
                }

                init() {
                }

                static func _flightRoute_show_0(_ make: @escaping @Sendable (FlightWeb.RequestContext) throws -> Self) -> FlightWeb.RouteRegistration {
                    FlightWeb.RouteRegistration(method: "GET", path: "/:id", kind: .http, source: String(reflecting: Self.self) + ".show") { context in
                        let controller = try make(context)
                        let result = controller.show(context)
                        return try FlightWeb.encodeResponse(result, for: context)
                    }
                }

                static func _flightRegister(_ container: FlightCore.Container) throws {
                    try _flightRegister(container, includingRoutes: true)
                }

                static func _flightRegister(_ container: FlightCore.Container, includingRoutes: Bool) throws {
                    container.register(Self.self, scope: .singleton, stereotype: .controller) { c in
                        try Self(_flight: c)
                    }
                    guard includingRoutes else {
                        return
                    }
                    container.register(FlightWeb.RouteRegistration.self, qualifier: "GET /:id @" + String(reflecting: Self.self) + ".show", scope: .singleton) { c in
                        let controller = try c.resolve(Self.self)
                        return Self._flightRoute_show_0 { _ in
                            controller
                        }
                    }
                }
            }

            extension BadController: FlightCore._FlightRegistrable {
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@Controller path 'users' must start with '/'.",
                    line: 1, column: 1
                )
            ],
            macroSpecs: testMacros
        )
    }

    @Test("controller path non literal is an error")
    func controllerPathNonLiteralIsAnError() {
        assertMacroExpansion(
            """
            @Controller(somePath)
            struct BadController {
                @GetRoute("/x")
                func handler(_ context: RequestContext) -> String { "x" }
            }
            """,
            expandedSource: """
            struct BadController {
                func handler(_ context: RequestContext) -> String { "x" }

                internal init(_flight container: FlightCore.Container) throws {
                }

                init() {
                }

                static func _flightRoute_handler_0(_ make: @escaping @Sendable (FlightWeb.RequestContext) throws -> Self) -> FlightWeb.RouteRegistration {
                    FlightWeb.RouteRegistration(method: "GET", path: "/x", kind: .http, source: String(reflecting: Self.self) + ".handler") { context in
                        let controller = try make(context)
                        let result = controller.handler(context)
                        return try FlightWeb.encodeResponse(result, for: context)
                    }
                }

                static func _flightRegister(_ container: FlightCore.Container) throws {
                    try _flightRegister(container, includingRoutes: true)
                }

                static func _flightRegister(_ container: FlightCore.Container, includingRoutes: Bool) throws {
                    container.register(Self.self, scope: .singleton, stereotype: .controller) { c in
                        try Self(_flight: c)
                    }
                    guard includingRoutes else {
                        return
                    }
                    container.register(FlightWeb.RouteRegistration.self, qualifier: "GET /x @" + String(reflecting: Self.self) + ".handler", scope: .singleton) { c in
                        let controller = try c.resolve(Self.self)
                        return Self._flightRoute_handler_0 { _ in
                            controller
                        }
                    }
                }
            }

            extension BadController: FlightCore._FlightRegistrable {
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@Controller's path must be a string literal — the route table is built at compile time (§4).",
                    line: 1, column: 13
                )
            ],
            macroSpecs: testMacros
        )
    }

    /// Duplicate detection runs on the *combined* path, not the bare
    /// method-level literal — the diagnostic names the full route
    /// (`GET /users/:id`), which is only visible once the base path folds
    /// in; two relative paths that are themselves distinct ("/:id" and
    /// "/:id" repeated is the trivial case, so this uses the "/" ⇔ base
    /// identity) still collide correctly.
    @Test("duplicate routes report the combined path")
    func duplicateRoutesReportTheCombinedPath() {
        assertMacroExpansion(
            """
            @Controller("/users")
            struct BadController {
                @GetRoute("/:id")
                func one(_ context: RequestContext) -> String { "1" }
                @GetRoute("/:id")
                func two(_ context: RequestContext) -> String { "2" }
            }
            """,
            expandedSource: """
            struct BadController {
                func one(_ context: RequestContext) -> String { "1" }
                func two(_ context: RequestContext) -> String { "2" }
            }

            extension BadController: FlightCore._FlightRegistrable {
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "Route 'GET /users/:id' is declared by both 'one' and 'two' in this controller.",
                    line: 5, column: 5
                )
            ],
            macroSpecs: testMacros
        )
    }

    @Test("a mapping attribute outside @Controller is diagnosed, not silently inert")
    func mappingOutsideControllerIsDiagnosed() {
        // The whole point of this fixture is the case a fixture is bad at
        // catching: it used to produce no output *and* no diagnostic, which
        // looks like nothing to assert. The route simply did not exist —
        // @Controller's expansion is what reads these attributes, so without
        // it nothing is generated and nothing complains. Same failure class
        // as GAPS.md's "@Scheduler shipped inert, and every check passed".
        assertMacroExpansion(
            """
            struct NotAController {
                @GetRoute("/users")
                func list(_ context: RequestContext) -> String { "x" }
            }
            """,
            expandedSource: """
            struct NotAController {
                func list(_ context: RequestContext) -> String { "x" }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: """
                        @GetRoute registers a route only on a method of a type annotated \
                        @Controller, which is what reads these attributes. This method's \
                        enclosing type is not annotated @Controller — nor is a method in an \
                        extension of one scanned — so the route would silently never exist. \
                        Add @Controller to the type declaring this method, or register the \
                        route with container.registerRoute.
                        """,
                    line: 2, column: 5
                )
            ],
            macroSpecs: testMacros
        )
    }

    @Test("a mapping in an extension of a controller is diagnosed too")
    func mappingInExtensionIsDiagnosed() {
        // Just as inert: @Controller reads its own member block, so a mapping
        // written in an extension is never scanned.
        assertMacroExpansion(
            """
            extension SomeController {
                @PostRoute("/users")
                func create(_ context: RequestContext) -> String { "x" }
            }
            """,
            expandedSource: """
            extension SomeController {
                func create(_ context: RequestContext) -> String { "x" }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: """
                        @PostRoute registers a route only on a method of a type annotated \
                        @Controller, which is what reads these attributes. This method's \
                        enclosing type is not annotated @Controller — nor is a method in an \
                        extension of one scanned — so the route would silently never exist. \
                        Add @Controller to the type declaring this method, or register the \
                        route with container.registerRoute.
                        """,
                    line: 2, column: 5
                )
            ],
            macroSpecs: testMacros
        )
    }

    @Test("a body: parameter on a WebSocket route is diagnosed, not accepted")
    func webSocketBodyParameterIsDiagnosed() {
        // Accepted by the scanner and then guaranteed to fail at runtime: an
        // upgrade request has an empty body by construction (RFC 6455 §4.1)
        // and `decodeRequestBody` rejects empty bodies, so the upgrade was
        // always refused, with nothing pointing at the `body:` that caused it.
        assertMacroExpansion(
            """
            @Controller
            struct ChatController {
                @WebSocketRoute("/chat")
                func chat(_ context: RequestContext, body: Hello) -> any WebSocketUpgradeHandler {
                    Handler()
                }
            }
            """,
            expandedSource: """
            struct ChatController {
                func chat(_ context: RequestContext, body: Hello) -> any WebSocketUpgradeHandler {
                    Handler()
                }

                internal init(_flight container: FlightCore.Container) throws {
                }

                init() {
                }

                static func _flightRegister(_ container: FlightCore.Container) throws {
                    try _flightRegister(container, includingRoutes: true)
                }

                static func _flightRegister(_ container: FlightCore.Container, includingRoutes: Bool) throws {
                    container.register(Self.self, scope: .singleton, stereotype: .controller) { c in
                        try Self(_flight: c)
                    }
                }
            }

            extension ChatController: FlightCore._FlightRegistrable {
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: """
                        A @WebSocketRoute handler cannot take a 'body:' parameter: an upgrade \
                        request has an empty body by construction (RFC 6455 §4.1), so decoding \
                        one always fails and the upgrade is always refused at runtime. Read \
                        what you need from the request's headers or query.
                        """,
                    line: 3, column: 5
                )
            ],
            macroSpecs: testMacros
        )
    }

    @Test("a route path containing a backslash is diagnosed at the attribute")
    func backslashPathIsDiagnosed() {
        // Re-embedded verbatim into generated string literals, so it used to
        // fail as a compile error inside an expansion, at a line nobody wrote.
        assertMacroExpansion(
            #"""
            @Controller
            struct BadController {
                @GetRoute("/a\b")
                func handler(_ context: RequestContext) -> String { "x" }
            }
            """#,
            expandedSource: #"""
            struct BadController {
                func handler(_ context: RequestContext) -> String { "x" }

                internal init(_flight container: FlightCore.Container) throws {
                }

                init() {
                }

                static func _flightRegister(_ container: FlightCore.Container) throws {
                    try _flightRegister(container, includingRoutes: true)
                }

                static func _flightRegister(_ container: FlightCore.Container, includingRoutes: Bool) throws {
                    container.register(Self.self, scope: .singleton, stereotype: .controller) { c in
                        try Self(_flight: c)
                    }
                }
            }

            extension BadController: FlightCore._FlightRegistrable {
            }
            """#,
            diagnostics: [
                DiagnosticSpec(
                    message: #"""
                        @GetRoute path "/a\b" contains a quote or a backslash. Neither is legal unescaped in a URL path; percent-encode it if it is genuinely part of the path.
                        """#,
                    line: 3, column: 5
                )
            ],
            macroSpecs: testMacros
        )
    }

    // MARK: Pipelines at controller and route (§2.7)

    @Test("a route inherits its controller's pipelines when it says nothing")
    func routeInheritsControllerPipelines() {
        assertMacroExpansion(
            """
            @Controller("/dashboard", pipelines: [.authenticated])
            struct DashboardController {
                @GetRoute("/admin")
                func admin(_ context: RequestContext) -> Response {
                    .noContent
                }
            }
            """,
            expandedSource: """
            struct DashboardController {
                func admin(_ context: RequestContext) -> Response {
                    .noContent
                }

                internal init(_flight container: FlightCore.Container) throws {
                }

                init() {
                }

                static func _flightRoute_admin_0(_ make: @escaping @Sendable (FlightWeb.RequestContext) throws -> Self) -> FlightWeb.RouteRegistration {
                    FlightWeb.RouteRegistration(method: "GET", path: "/dashboard/admin", kind: .http, source: String(reflecting: Self.self) + ".admin", pipelines: [.authenticated]) { context in
                        let controller = try make(context)
                        let result = controller.admin(context)
                        return try FlightWeb.encodeResponse(result, for: context)
                    }
                }

                static func _flightRegister(_ container: FlightCore.Container) throws {
                    try _flightRegister(container, includingRoutes: true)
                }

                static func _flightRegister(_ container: FlightCore.Container, includingRoutes: Bool) throws {
                    container.register(Self.self, scope: .singleton, stereotype: .controller) { c in
                        try Self(_flight: c)
                    }
                    guard includingRoutes else {
                        return
                    }
                    container.register(FlightWeb.RouteRegistration.self, qualifier: "GET /dashboard/admin @" + String(reflecting: Self.self) + ".admin", scope: .singleton) { c in
                        let controller = try c.resolve(Self.self)
                        return Self._flightRoute_admin_0 { _ in
                            controller
                        }
                    }
                }
            }

            extension DashboardController: FlightCore._FlightRegistrable {
            }
            """,
            macroSpecs: testMacros
        )
    }

    /// Replace, not append: the route's list is the whole stack. Saying
    /// `.public` is also the acknowledgment that silences the narrowing
    /// warning.
    @Test("a route's own pipelines replace the controller's")
    func routePipelinesReplaceControllers() {
        assertMacroExpansion(
            """
            @Controller("/dashboard", pipelines: [.authenticated])
            struct DashboardController {
                @GetRoute("/", pipelines: [.public])
                func index(_ context: RequestContext) -> Response {
                    .noContent
                }
            }
            """,
            expandedSource: """
            struct DashboardController {
                func index(_ context: RequestContext) -> Response {
                    .noContent
                }

                internal init(_flight container: FlightCore.Container) throws {
                }

                init() {
                }

                static func _flightRoute_index_0(_ make: @escaping @Sendable (FlightWeb.RequestContext) throws -> Self) -> FlightWeb.RouteRegistration {
                    FlightWeb.RouteRegistration(method: "GET", path: "/dashboard", kind: .http, source: String(reflecting: Self.self) + ".index", pipelines: [.public]) { context in
                        let controller = try make(context)
                        let result = controller.index(context)
                        return try FlightWeb.encodeResponse(result, for: context)
                    }
                }

                static func _flightRegister(_ container: FlightCore.Container) throws {
                    try _flightRegister(container, includingRoutes: true)
                }

                static func _flightRegister(_ container: FlightCore.Container, includingRoutes: Bool) throws {
                    container.register(Self.self, scope: .singleton, stereotype: .controller) { c in
                        try Self(_flight: c)
                    }
                    guard includingRoutes else {
                        return
                    }
                    container.register(FlightWeb.RouteRegistration.self, qualifier: "GET /dashboard @" + String(reflecting: Self.self) + ".index", scope: .singleton) { c in
                        let controller = try c.resolve(Self.self)
                        return Self._flightRoute_index_0 { _ in
                            controller
                        }
                    }
                }
            }

            extension DashboardController: FlightCore._FlightRegistrable {
            }
            """,
            macroSpecs: testMacros
        )
    }

    /// The mistake worth catching: narrowing away the controller's
    /// authentication without saying so. A warning, not an error — the
    /// author is entitled to make this call, they just have to mean it.
    @Test("dropping the controller's auth without saying .public warns")
    func narrowingAwayAuthenticationWarns() {
        assertMacroExpansion(
            """
            @Controller("/dashboard", pipelines: [.authenticated])
            struct DashboardController {
                @GetRoute("/", pipelines: ["metrics"])
                func index(_ context: RequestContext) -> Response {
                    .noContent
                }
            }
            """,
            expandedSource: """
            struct DashboardController {
                func index(_ context: RequestContext) -> Response {
                    .noContent
                }

                internal init(_flight container: FlightCore.Container) throws {
                }

                init() {
                }

                static func _flightRoute_index_0(_ make: @escaping @Sendable (FlightWeb.RequestContext) throws -> Self) -> FlightWeb.RouteRegistration {
                    FlightWeb.RouteRegistration(method: "GET", path: "/dashboard", kind: .http, source: String(reflecting: Self.self) + ".index", pipelines: ["metrics"]) { context in
                        let controller = try make(context)
                        let result = controller.index(context)
                        return try FlightWeb.encodeResponse(result, for: context)
                    }
                }

                static func _flightRegister(_ container: FlightCore.Container) throws {
                    try _flightRegister(container, includingRoutes: true)
                }

                static func _flightRegister(_ container: FlightCore.Container, includingRoutes: Bool) throws {
                    container.register(Self.self, scope: .singleton, stereotype: .controller) { c in
                        try Self(_flight: c)
                    }
                    guard includingRoutes else {
                        return
                    }
                    container.register(FlightWeb.RouteRegistration.self, qualifier: "GET /dashboard @" + String(reflecting: Self.self) + ".index", scope: .singleton) { c in
                        let controller = try c.resolve(Self.self)
                        return Self._flightRoute_index_0 { _ in
                            controller
                        }
                    }
                }
            }

            extension DashboardController: FlightCore._FlightRegistrable {
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: """
                        'index' replaces its controller's pipelines and drops .authenticated, so this route runs without authentication. A route's 'pipelines:' replaces the controller's rather than adding to it. If that is intended, say 'pipelines: [.public]' — that is how a deliberately public route records the decision.
                        """,
                    line: 3, column: 5, severity: .warning
                )
            ],
            macroSpecs: testMacros
        )
    }

    /// Swapping one security lane for another is a change, not a drop — no
    /// warning, because authentication still runs.
    @Test("swapping one security lane for another does not warn")
    func swappingSecurityLanesDoesNotWarn() {
        assertMacroExpansion(
            """
            @Controller("/dashboard", pipelines: [.authenticated])
            struct DashboardController {
                @GetRoute("/", pipelines: [.authentication])
                func index(_ context: RequestContext) -> Response {
                    .noContent
                }
            }
            """,
            expandedSource: """
            struct DashboardController {
                func index(_ context: RequestContext) -> Response {
                    .noContent
                }

                internal init(_flight container: FlightCore.Container) throws {
                }

                init() {
                }

                static func _flightRoute_index_0(_ make: @escaping @Sendable (FlightWeb.RequestContext) throws -> Self) -> FlightWeb.RouteRegistration {
                    FlightWeb.RouteRegistration(method: "GET", path: "/dashboard", kind: .http, source: String(reflecting: Self.self) + ".index", pipelines: [.authentication]) { context in
                        let controller = try make(context)
                        let result = controller.index(context)
                        return try FlightWeb.encodeResponse(result, for: context)
                    }
                }

                static func _flightRegister(_ container: FlightCore.Container) throws {
                    try _flightRegister(container, includingRoutes: true)
                }

                static func _flightRegister(_ container: FlightCore.Container, includingRoutes: Bool) throws {
                    container.register(Self.self, scope: .singleton, stereotype: .controller) { c in
                        try Self(_flight: c)
                    }
                    guard includingRoutes else {
                        return
                    }
                    container.register(FlightWeb.RouteRegistration.self, qualifier: "GET /dashboard @" + String(reflecting: Self.self) + ".index", scope: .singleton) { c in
                        let controller = try c.resolve(Self.self)
                        return Self._flightRoute_index_0 { _ in
                            controller
                        }
                    }
                }
            }

            extension DashboardController: FlightCore._FlightRegistrable {
            }
            """,
            macroSpecs: testMacros
        )
    }
}
