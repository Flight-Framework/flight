// Flight Web §4 — controller macro expansions, pinned as fixtures.
//
// Same discipline as FlightCoreMacroTests: these expected strings are the
// normative expansion spec; the design doc's prose examples are
// illustrative. The runtime integration suite (FlightWebTests) proves the
// compiled path end-to-end; these pin the generated *shape*.

import SwiftSyntax
import SwiftSyntaxMacroExpansion
import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import XCTest

@testable import FlightWebMacrosImpl

private let testMacros: [String: MacroSpec] = [
    "Controller": MacroSpec(type: ControllerMacro.self, conformances: ["FlightCore._FlightRegistrable"]),
    "GetMapping": MacroSpec(type: RouteMappingMacro.self),
    "PostMapping": MacroSpec(type: RouteMappingMacro.self),
    "DeleteMapping": MacroSpec(type: RouteMappingMacro.self),
    "WebSocketMapping": MacroSpec(type: RouteMappingMacro.self),
]

final class ControllerMacroFixtureTests: XCTestCase {

    // MARK: Fixture 1 — plain GET handler with a return value

    func testGetHandlerExpansion() {
        assertMacroExpansion(
            """
            @Controller
            struct HealthController {
                @GetMapping("/health")
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

                static func _flightRegister(_ container: FlightCore.Container) throws {
                    container.register(Self.self, scope: .singleton) { c in
                        try Self(_flight: c)
                    }
                    container.register(FlightWeb.RouteRegistration.self, qualifier: "GET /health @" + String(reflecting: Self.self) + ".health", scope: .singleton) { c in
                        let controller = try c.resolve(Self.self)
                        return FlightWeb.RouteRegistration(method: "GET", path: "/health", kind: .http, source: String(reflecting: Self.self) + ".health") { context in
                            let result = try await controller.health(context)
                            return try FlightWeb.encodeResponse(result, for: context)
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

    // MARK: Fixture 2 — body-decoding POST + @Autowired + Void DELETE

    func testBodyAndVoidHandlers() {
        assertMacroExpansion(
            """
            @Controller
            public struct UserController {
                @Autowired var userService: UserService

                @PostMapping("/users")
                func createUser(_ context: RequestContext, body: CreateUserRequest) async throws -> UserResponse {
                    try await userService.create(body)
                }

                @DeleteMapping("/users/:id")
                func deleteUser(_ context: RequestContext) throws {
                    try userService.delete(context.pathParam("id"))
                }
            }
            """,
            expandedSource: """
            public struct UserController {
                @Autowired var userService: UserService
                func createUser(_ context: RequestContext, body: CreateUserRequest) async throws -> UserResponse {
                    try await userService.create(body)
                }
                func deleteUser(_ context: RequestContext) throws {
                    try userService.delete(context.pathParam("id"))
                }

                internal init(_flight container: FlightCore.Container) throws {
                    self.userService = try container.resolve(UserService.self)
                }

                public static func _flightRegister(_ container: FlightCore.Container) throws {
                    container.register(Self.self, scope: .singleton) { c in
                        try Self(_flight: c)
                    }
                    container.register(FlightWeb.RouteRegistration.self, qualifier: "POST /users @" + String(reflecting: Self.self) + ".createUser", scope: .singleton) { c in
                        let controller = try c.resolve(Self.self)
                        return FlightWeb.RouteRegistration(method: "POST", path: "/users", kind: .http, source: String(reflecting: Self.self) + ".createUser") { context in
                            let body = try FlightWeb.decodeRequestBody(CreateUserRequest.self, from: context)
                            let result = try await controller.createUser(context, body: body)
                            return try FlightWeb.encodeResponse(result, for: context)
                        }
                    }
                    container.register(FlightWeb.RouteRegistration.self, qualifier: "DELETE /users/:id @" + String(reflecting: Self.self) + ".deleteUser", scope: .singleton) { c in
                        let controller = try c.resolve(Self.self)
                        return FlightWeb.RouteRegistration(method: "DELETE", path: "/users/:id", kind: .http, source: String(reflecting: Self.self) + ".deleteUser") { context in
                            try controller.deleteUser(context)
                            return FlightWeb.Response.noContent
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

    func testWebSocketMappingExpansion() {
        assertMacroExpansion(
            """
            @Controller
            struct ChatController {
                @WebSocketMapping("/chat/:roomId")
                func chat(_ context: RequestContext) async throws -> ConnectionUpgradeHandler {
                    ChatRoomHandler(roomId: context.pathParam("roomId")!)
                }
            }
            """,
            expandedSource: """
            struct ChatController {
                func chat(_ context: RequestContext) async throws -> ConnectionUpgradeHandler {
                    ChatRoomHandler(roomId: context.pathParam("roomId")!)
                }

                internal init(_flight container: FlightCore.Container) throws {
                }

                static func _flightRegister(_ container: FlightCore.Container) throws {
                    container.register(Self.self, scope: .singleton) { c in
                        try Self(_flight: c)
                    }
                    container.register(FlightWeb.RouteRegistration.self, qualifier: "GET /chat/:roomId @" + String(reflecting: Self.self) + ".chat", scope: .singleton) { c in
                        let controller = try c.resolve(Self.self)
                        return FlightWeb.RouteRegistration(method: "GET", path: "/chat/:roomId", kind: .upgrade, source: String(reflecting: Self.self) + ".chat") { context in
                            let upgradeHandler = try await controller.chat(context)
                            return FlightWeb.Response.upgrade(handler: upgradeHandler, context: context)
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

    func testNonLiteralPathIsAnError() {
        assertMacroExpansion(
            """
            @Controller
            struct BadController {
                @GetMapping(somePath)
                func handler(_ context: RequestContext) -> String { "x" }
            }
            """,
            expandedSource: """
            struct BadController {
                func handler(_ context: RequestContext) -> String { "x" }

                internal init(_flight container: FlightCore.Container) throws {
                }

                static func _flightRegister(_ container: FlightCore.Container) throws {
                    container.register(Self.self, scope: .singleton) { c in
                        try Self(_flight: c)
                    }
                }
            }

            extension BadController: FlightCore._FlightRegistrable {
            }
            """,
            diagnostics: [
                // Once from @Controller's scan, once from the peer marker.
                DiagnosticSpec(
                    message: "@GetMapping requires a string-literal path — the route table is built at compile time (§4).",
                    line: 3, column: 5
                ),
                DiagnosticSpec(
                    message: "@GetMapping requires a string-literal path — the route table is built at compile time (§4).",
                    line: 3, column: 5
                ),
            ],
            macroSpecs: testMacros
        )
    }

    func testStaticHandlerIsAnError() {
        assertMacroExpansion(
            """
            @Controller
            struct BadController {
                @GetMapping("/x")
                static func handler(_ context: RequestContext) -> String { "x" }
            }
            """,
            expandedSource: """
            struct BadController {
                static func handler(_ context: RequestContext) -> String { "x" }

                internal init(_flight container: FlightCore.Container) throws {
                }

                static func _flightRegister(_ container: FlightCore.Container) throws {
                    container.register(Self.self, scope: .singleton) { c in
                        try Self(_flight: c)
                    }
                }
            }

            extension BadController: FlightCore._FlightRegistrable {
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "Route handler 'handler' must be an instance method — the container resolves the controller instance per registration.",
                    line: 3, column: 5
                ),
                DiagnosticSpec(
                    message: "Route handler 'handler' must be an instance method — the container resolves the controller instance per registration.",
                    line: 3, column: 5
                ),
            ],
            macroSpecs: testMacros
        )
    }

    func testMissingContextParameterIsAnError() {
        assertMacroExpansion(
            """
            @Controller
            struct BadController {
                @GetMapping("/x")
                func handler() -> String { "x" }
            }
            """,
            expandedSource: """
            struct BadController {
                func handler() -> String { "x" }

                internal init(_flight container: FlightCore.Container) throws {
                }

                static func _flightRegister(_ container: FlightCore.Container) throws {
                    container.register(Self.self, scope: .singleton) { c in
                        try Self(_flight: c)
                    }
                }
            }

            extension BadController: FlightCore._FlightRegistrable {
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "Route handler 'handler' must take '_ context: RequestContext' as its first parameter.",
                    line: 3, column: 5
                ),
                DiagnosticSpec(
                    message: "Route handler 'handler' must take '_ context: RequestContext' as its first parameter.",
                    line: 3, column: 5
                ),
            ],
            macroSpecs: testMacros
        )
    }

    func testDuplicateRoutesInOneControllerAreAnError() {
        assertMacroExpansion(
            """
            @Controller
            struct BadController {
                @GetMapping("/same")
                func one(_ context: RequestContext) -> String { "1" }
                @GetMapping("/same")
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

    func testNonFinalClassControllerIsAnError() {
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

    func testInvalidPathPatternIsAnError() {
        assertMacroExpansion(
            """
            @Controller
            struct BadController {
                @GetMapping("users")
                func handler(_ context: RequestContext) -> String { "x" }
            }
            """,
            expandedSource: """
            struct BadController {
                func handler(_ context: RequestContext) -> String { "x" }

                internal init(_flight container: FlightCore.Container) throws {
                }

                static func _flightRegister(_ container: FlightCore.Container) throws {
                    container.register(Self.self, scope: .singleton) { c in
                        try Self(_flight: c)
                    }
                    container.register(FlightWeb.RouteRegistration.self, qualifier: "GET users @" + String(reflecting: Self.self) + ".handler", scope: .singleton) { c in
                        let controller = try c.resolve(Self.self)
                        return FlightWeb.RouteRegistration(method: "GET", path: "users", kind: .http, source: String(reflecting: Self.self) + ".handler") { context in
                            let result = controller.handler(context)
                            return try FlightWeb.encodeResponse(result, for: context)
                        }
                    }
                }
            }

            extension BadController: FlightCore._FlightRegistrable {
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@GetMapping path 'users' must start with '/'.",
                    line: 3, column: 5
                )
            ],
            macroSpecs: testMacros
        )
    }

    // MARK: Fixture 4 — @Controller base path, Spring-style combination

    func testControllerBasePathCombinesWithMethodPaths() {
        assertMacroExpansion(
            """
            @Controller("/users")
            struct UserController {
                @GetMapping("/")
                func index(_ context: RequestContext) -> String { "x" }

                @GetMapping("/:id")
                func show(_ context: RequestContext) -> String { "x" }
            }
            """,
            expandedSource: """
            struct UserController {
                func index(_ context: RequestContext) -> String { "x" }
                func show(_ context: RequestContext) -> String { "x" }

                internal init(_flight container: FlightCore.Container) throws {
                }

                static func _flightRegister(_ container: FlightCore.Container) throws {
                    container.register(Self.self, scope: .singleton) { c in
                        try Self(_flight: c)
                    }
                    container.register(FlightWeb.RouteRegistration.self, qualifier: "GET /users @" + String(reflecting: Self.self) + ".index", scope: .singleton) { c in
                        let controller = try c.resolve(Self.self)
                        return FlightWeb.RouteRegistration(method: "GET", path: "/users", kind: .http, source: String(reflecting: Self.self) + ".index") { context in
                            let result = controller.index(context)
                            return try FlightWeb.encodeResponse(result, for: context)
                        }
                    }
                    container.register(FlightWeb.RouteRegistration.self, qualifier: "GET /users/:id @" + String(reflecting: Self.self) + ".show", scope: .singleton) { c in
                        let controller = try c.resolve(Self.self)
                        return FlightWeb.RouteRegistration(method: "GET", path: "/users/:id", kind: .http, source: String(reflecting: Self.self) + ".show") { context in
                            let result = controller.show(context)
                            return try FlightWeb.encodeResponse(result, for: context)
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
    func testControllerBasePathTrailingSlashCollapses() {
        assertMacroExpansion(
            """
            @Controller("/users/")
            struct UserController {
                @GetMapping("/:id")
                func show(_ context: RequestContext) -> String { "x" }
            }
            """,
            expandedSource: """
            struct UserController {
                func show(_ context: RequestContext) -> String { "x" }

                internal init(_flight container: FlightCore.Container) throws {
                }

                static func _flightRegister(_ container: FlightCore.Container) throws {
                    container.register(Self.self, scope: .singleton) { c in
                        try Self(_flight: c)
                    }
                    container.register(FlightWeb.RouteRegistration.self, qualifier: "GET /users/:id @" + String(reflecting: Self.self) + ".show", scope: .singleton) { c in
                        let controller = try c.resolve(Self.self)
                        return FlightWeb.RouteRegistration(method: "GET", path: "/users/:id", kind: .http, source: String(reflecting: Self.self) + ".show") { context in
                            let result = controller.show(context)
                            return try FlightWeb.encodeResponse(result, for: context)
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
    func testOmittedControllerPathIsUnprefixed() {
        assertMacroExpansion(
            """
            @Controller
            struct HealthController {
                @GetMapping("/health")
                func health(_ context: RequestContext) -> String { "ok" }
            }
            """,
            expandedSource: """
            struct HealthController {
                func health(_ context: RequestContext) -> String { "ok" }

                internal init(_flight container: FlightCore.Container) throws {
                }

                static func _flightRegister(_ container: FlightCore.Container) throws {
                    container.register(Self.self, scope: .singleton) { c in
                        try Self(_flight: c)
                    }
                    container.register(FlightWeb.RouteRegistration.self, qualifier: "GET /health @" + String(reflecting: Self.self) + ".health", scope: .singleton) { c in
                        let controller = try c.resolve(Self.self)
                        return FlightWeb.RouteRegistration(method: "GET", path: "/health", kind: .http, source: String(reflecting: Self.self) + ".health") { context in
                            let result = controller.health(context)
                            return try FlightWeb.encodeResponse(result, for: context)
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

    func testControllerPathMustStartWithSlash() {
        assertMacroExpansion(
            """
            @Controller("users")
            struct BadController {
                @GetMapping("/:id")
                func show(_ context: RequestContext) -> String { "x" }
            }
            """,
            expandedSource: """
            struct BadController {
                func show(_ context: RequestContext) -> String { "x" }

                internal init(_flight container: FlightCore.Container) throws {
                }

                static func _flightRegister(_ container: FlightCore.Container) throws {
                    container.register(Self.self, scope: .singleton) { c in
                        try Self(_flight: c)
                    }
                    container.register(FlightWeb.RouteRegistration.self, qualifier: "GET /:id @" + String(reflecting: Self.self) + ".show", scope: .singleton) { c in
                        let controller = try c.resolve(Self.self)
                        return FlightWeb.RouteRegistration(method: "GET", path: "/:id", kind: .http, source: String(reflecting: Self.self) + ".show") { context in
                            let result = controller.show(context)
                            return try FlightWeb.encodeResponse(result, for: context)
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

    func testControllerPathNonLiteralIsAnError() {
        assertMacroExpansion(
            """
            @Controller(somePath)
            struct BadController {
                @GetMapping("/x")
                func handler(_ context: RequestContext) -> String { "x" }
            }
            """,
            expandedSource: """
            struct BadController {
                func handler(_ context: RequestContext) -> String { "x" }

                internal init(_flight container: FlightCore.Container) throws {
                }

                static func _flightRegister(_ container: FlightCore.Container) throws {
                    container.register(Self.self, scope: .singleton) { c in
                        try Self(_flight: c)
                    }
                    container.register(FlightWeb.RouteRegistration.self, qualifier: "GET /x @" + String(reflecting: Self.self) + ".handler", scope: .singleton) { c in
                        let controller = try c.resolve(Self.self)
                        return FlightWeb.RouteRegistration(method: "GET", path: "/x", kind: .http, source: String(reflecting: Self.self) + ".handler") { context in
                            let result = controller.handler(context)
                            return try FlightWeb.encodeResponse(result, for: context)
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
    func testDuplicateRoutesReportTheCombinedPath() {
        assertMacroExpansion(
            """
            @Controller("/users")
            struct BadController {
                @GetMapping("/:id")
                func one(_ context: RequestContext) -> String { "1" }
                @GetMapping("/:id")
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
}
