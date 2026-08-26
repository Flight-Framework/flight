// @Middleware expansion fixtures — same discipline as
// ControllerMacroFixtureTests: these expected strings are the spec.

import SwiftSyntax
import SwiftSyntaxMacroExpansion
import SwiftSyntaxMacros
import SwiftSyntaxMacrosGenericTestSupport
import Testing

@testable import FlightCoreMacrosImpl
@testable import FlightWebMacrosImpl

private let testMacros: [String: MacroSpec] = [
    "Middleware": MacroSpec(
        type: MiddlewareMacro.self,
        conformances: ["FlightCore._FlightRegistrable", "FlightWeb.Middleware"]),
    "Autowired": MacroSpec(type: AutowiredMacro.self),
]

@Suite("@Middleware expansion")
struct MiddlewareMacroFixtureTests {

    @Test("no dependencies: an empty resolving init, always .singleton and .middleware")
    func plainMiddleware() {
        assertMacroExpansion(
            """
            @Middleware
            struct RequestTiming {
                func handle(_ context: RequestContext, next: Next) async throws -> Response { try await next(context) }
            }
            """,
            expandedSource: """
                struct RequestTiming {
                    func handle(_ context: RequestContext, next: Next) async throws -> Response { try await next(context) }

                    internal init(_flight container: FlightCore.Container) throws {
                    }

                    static func _flightRegister(_ container: FlightCore.Container) throws {
                        container.register(Self.self, scope: .singleton, stereotype: .middleware) { c in
                            try Self(_flight: c)
                        }
                    }
                }

                extension RequestTiming: FlightCore._FlightRegistrable {
                }

                extension RequestTiming: FlightWeb.Middleware {
                }
                """,
            macroSpecs: testMacros
        )
    }

    @Test("@Autowired dependencies resolve exactly like @Component")
    func withDependencies() {
        assertMacroExpansion(
            """
            @Middleware
            public struct Transactions {
                @Autowired var container: Container
                @Autowired var settings: WebSettings
                func handle(_ context: RequestContext, next: Next) async throws -> Response { try await next(context) }
            }
            """,
            expandedSource: """
                public struct Transactions {
                    var container: Container
                    var settings: WebSettings
                    func handle(_ context: RequestContext, next: Next) async throws -> Response { try await next(context) }

                    internal init(_flight container: FlightCore.Container) throws {
                        self.container = try container.resolve(Container.self)
                        self.settings = try container.resolve(WebSettings.self)
                    }

                    public static func _flightRegister(_ container: FlightCore.Container) throws {
                        container.register(Self.self, scope: .singleton, stereotype: .middleware) { c in
                            try Self(_flight: c)
                        }
                    }
                }

                extension Transactions: FlightCore._FlightRegistrable {
                }

                extension Transactions: FlightWeb.Middleware {
                }
                """,
            macroSpecs: testMacros
        )
    }

    @Test("no scope: or qualifier: argument is accepted — @Middleware takes none")
    func noArguments() {
        assertMacroExpansion(
            """
            @Middleware
            struct Plain {
                func handle(_ context: RequestContext, next: Next) async throws -> Response { try await next(context) }
            }
            """,
            expandedSource: """
                struct Plain {
                    func handle(_ context: RequestContext, next: Next) async throws -> Response { try await next(context) }

                    internal init(_flight container: FlightCore.Container) throws {
                    }

                    static func _flightRegister(_ container: FlightCore.Container) throws {
                        container.register(Self.self, scope: .singleton, stereotype: .middleware) { c in
                            try Self(_flight: c)
                        }
                    }
                }

                extension Plain: FlightCore._FlightRegistrable {
                }

                extension Plain: FlightWeb.Middleware {
                }
                """,
            macroSpecs: testMacros
        )
    }
}

@Suite("@Middleware diagnostics")
struct MiddlewareMacroDiagnosticTests {

    @Test("attaching to a non-final class is refused")
    func nonFinalClassRefused() {
        assertMacroExpansion(
            """
            @Middleware
            class RequestTiming {
                func handle(_ context: RequestContext, next: Next) async throws -> Response { try await next(context) }
            }
            """,
            expandedSource: """
                class RequestTiming {
                    func handle(_ context: RequestContext, next: Next) async throws -> Response { try await next(context) }
                }

                extension RequestTiming: FlightCore._FlightRegistrable {
                }

                extension RequestTiming: FlightWeb.Middleware {
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@Middleware requires a final class (or a struct). Mark 'RequestTiming' final.",
                    line: 2, column: 7)
            ],
            macroSpecs: testMacros
        )
    }

    @Test("an uninitialized non-injected property is rejected, naming the fix")
    func uninitializedStoredPropertyIsRejected() {
        assertMacroExpansion(
            """
            @Middleware
            struct RequestTiming {
                let label: String
                func handle(_ context: RequestContext, next: Next) async throws -> Response { try await next(context) }
            }
            """,
            expandedSource: """
                struct RequestTiming {
                    let label: String
                    func handle(_ context: RequestContext, next: Next) async throws -> Response { try await next(context) }
                }

                extension RequestTiming: FlightCore._FlightRegistrable {
                }

                extension RequestTiming: FlightWeb.Middleware {
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message: "Stored property 'label' of a @Middleware type needs a default value — the generated init(_flight:) assigns only @Autowired/@ConfigValue properties.",
                    line: 3, column: 5)
            ],
            macroSpecs: testMacros
        )
    }

    @Test("two @Autowired properties of the same type need distinct qualifiers")
    func ambiguousAutowiredIsRejected() {
        assertMacroExpansion(
            """
            @Middleware
            struct Fanout {
                @Autowired var primary: Backend
                @Autowired var secondary: Backend
                func handle(_ context: RequestContext, next: Next) async throws -> Response { try await next(context) }
            }
            """,
            expandedSource: """
                struct Fanout {
                    var primary: Backend
                    var secondary: Backend
                    func handle(_ context: RequestContext, next: Next) async throws -> Response { try await next(context) }
                }

                extension Fanout: FlightCore._FlightRegistrable {
                }

                extension Fanout: FlightWeb.Middleware {
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message: "Two @Autowired properties of type 'Backend' require distinct explicit qualifiers, e.g. @Autowired(\"primary\").",
                    line: 4, column: 5)
            ],
            macroSpecs: testMacros
        )
    }
}
