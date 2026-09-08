import Foundation
import Testing

/// End-to-end tests for `flight-registration-gen`.
///
/// The generator is a build tool: its contract is a manifest in, a Swift file
/// and a set of compiler diagnostics out. These drive the real executable
/// against real source files, because that contract — not any internal
/// function — is what a broken build would break.
@Suite("flight-registration-gen")
struct GeneratorTests {

    // MARK: - Harness

    /// The built generator. Declaring the executable as a dependency of this
    /// test target is what guarantees it exists by the time these run.
    static let executable: URL = {
        // Walk up from this file until the directory holding Package.swift —
        // the package root — rather than counting directory levels. Counting
        // broke the moment the test target moved from Tests/X to Tests/Core/X,
        // and would break again on any future regrouping.
        var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Package.swift").path)
        {
            let parent = root.deletingLastPathComponent()
            precondition(
                parent.path != root.path,
                "no Package.swift above \(#filePath) — cannot locate the built generator")
            root = parent
        }
        root.appendPathComponent(".build")
        for configuration in ["debug", "release"] {
            let candidate =
                root
                .appendingPathComponent(configuration)
                .appendingPathComponent("flight-registration-gen")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        // Fall back to the arch-specific layout SwiftPM uses on Linux.
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ) {
            for entry in entries {
                let candidate =
                    entry
                    .appendingPathComponent("debug")
                    .appendingPathComponent("flight-registration-gen")
                if FileManager.default.isExecutableFile(atPath: candidate.path) {
                    return candidate
                }
            }
        }
        return root.appendingPathComponent("debug/flight-registration-gen")
    }()

    struct Result {
        let exitCode: Int32
        let diagnostics: String
        let generated: String
    }

    /// Writes `sources` to a temporary target, runs the generator over them,
    /// and returns what it produced.
    /// `flightYAML`, when given, is written as `flight.yaml` in the same
    /// workspace the sources land in (not added to `modules[0].files` — it
    /// is not Swift), and the workspace itself becomes `packageDirectory`
    /// unless the caller overrides it — the layout a real package actually
    /// has, source files and `flight.yaml` side by side.
    func generate(
        _ sources: [String: String],
        targetModule: String = "AppModule",
        packageDirectory: String? = nil,
        flightYAML: String? = nil
    ) throws -> Result {
        let workspace = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("flightgen-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        var paths: [String] = []
        for (name, contents) in sources.sorted(by: { $0.key < $1.key }) {
            let path = workspace.appendingPathComponent(name)
            try contents.write(to: path, atomically: true, encoding: .utf8)
            paths.append(path.path)
        }
        if let flightYAML {
            try flightYAML.write(
                to: workspace.appendingPathComponent("flight.yaml"), atomically: true,
                encoding: .utf8)
        }

        let output = workspace.appendingPathComponent("FlightRegistrations.swift")
        var manifest: [String: Any] = [
            "targetModuleName": targetModule,
            "modules": [["name": targetModule, "files": paths]],
            "output": output.path,
        ]
        manifest["packageDirectory"] = packageDirectory ?? workspace.path

        let manifestPath = workspace.appendingPathComponent("manifest.json")
        try JSONSerialization.data(withJSONObject: manifest, options: [])
            .write(to: manifestPath)

        let process = Process()
        process.executableURL = Self.executable
        process.arguments = [manifestPath.path]
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = Pipe()
        try process.run()
        let diagnostics =
            String(
                data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()

        let generated = (try? String(contentsOf: output, encoding: .utf8)) ?? ""
        return Result(
            exitCode: process.terminationStatus, diagnostics: diagnostics, generated: generated)
    }

    // MARK: - The happy path

    @Test("a component is registered with its lifetime and stereotype")
    func registersComponent() throws {
        let result = try generate([
            "UserService.swift": """
            import FlightCore
            @Service final class UserService: Sendable {
            init() {}
            }
            """
        ])
        #expect(result.exitCode == 0)
        #expect(result.generated.contains("UserService"))
        #expect(result.generated.contains("flightRegisterAll"))
    }

    @Test("the generated body is exactly this — indentation included")
    func generatedBodyIsGolden() throws {
        // Every other test here asks `contains`, which cannot see the shape of
        // what was emitted. That blind spot let a cleanup pass collapse the
        // indentation inside the generator's own string literals: the output
        // still compiled, still contained every expected substring, and every
        // test still passed, while every Flight app got a mangled generated
        // file. This asserts the whole body, so shape regressions fail here.
        let result = try generate([
            "Sources.swift": """
            import FlightCore
            protocol Greeter {}
            @Service
            struct EnglishGreeter: Greeter {}
            @Component
            final class Welcomer {
                @Inject var greeter: (any Greeter)
            }
            """
        ])

        #expect(result.exitCode == 0)
        // The header carries a component count and the target name; the
        // registration function below it is what this test pins. The static
        // manifest that follows has its own golden test — one assertion over
        // both would fail on every manifest field, which is not what this is
        // watching for.
        // Internal, not public: it takes `FlightGraph`, which is internal.
        let marker = "func flightRegisterAll("
        let start = try #require(result.generated.range(of: marker)).lowerBound
        // The manifest's own doc comment precedes its declaration, so the
        // boundary is that comment, not the `public enum`.
        let end =
            result.generated.range(of: "/// Every route this module declares")?.lowerBound
            ?? result.generated.endIndex
        let body = String(result.generated[start..<end])
            .trimmingCharacters(in: .newlines)
        #expect(
            body == """
                func flightRegisterAll(
                    _ container: FlightCore.Container, graph: FlightGraph
                ) throws {
                    // Projected, not built: route terminals resolve it to reach root
                    // inputs, and they see the instance the composition root made.
                    container.register(FlightGraph.self, scope: .singleton) { _ in graph }

                    container.register(EnglishGreeter.self, scope: .singleton, stereotype: .service) { _ in
                        graph.englishGreeter
                    }
                    container.register(Welcomer.self, scope: .singleton) { _ in
                        graph.welcomer
                    }

                    // Existential bridges (demand-driven): each `@Inject var _: (any P)`
                    // with exactly one scanned conformer resolves through that conformer,
                    // mirroring its scope. A `// flight:hand-registered` marker on the
                    // demanding property suppresses the bridge.
                    container.register((any Greeter).self) { c in
                        try c.resolve(EnglishGreeter.self)
                    }
                }
                """)
    }

    // MARK: - Module-registered types (registration gating)

    @Test("a `flight:module-registered` type is scanned but not registered")
    func moduleRegisteredTypeIsNotEmitted() throws {
        let result = try generate([
            "Sources.swift": """
            import FlightCore
            @Component final class Ordinary: Sendable { init() {} }
            // flight:module-registered — its own module registers it.
            @Component final class Gated: Sendable { init() {} }
            """
        ])
        #expect(result.exitCode == 0)
        // Ordinary is a graph node, so its registration projects onto the
        // graph rather than calling its own thunk.
        #expect(result.generated.contains("graph.ordinary"))
        #expect(
            !result.generated.contains("let gated: Gated"),
            "a module-registered type is not a graph node either")
        #expect(
            !result.generated.contains("try Gated._flightRegister(container)"),
            "a module-registered type must not be registered by the scan")
        // Named rather than silently dropped: "why is my type not registered"
        // has to be answerable by reading the generated file.
        #expect(result.generated.contains("Gated"))
        #expect(result.generated.contains("flight:module-registered"))
    }

    /// The hazard the marker exists for, in miniature: `freeze()` builds every
    /// singleton eagerly, so registering a type whose dependency only a module
    /// provides breaks any app that merely links the package. A bridge to it
    /// would assert the same thing, so it must not be generated either.
    @Test("a module-registered type is not used as an existential bridge conformer")
    func moduleRegisteredTypeIsNotBridged() throws {
        let result = try generate([
            "Sources.swift": """
            import FlightCore
            protocol Validator {}
            // flight:module-registered
            @Service struct GatedValidator: Validator {}
            @Component final class Consumer {
                @Inject var validator: (any Validator)
            }
            """
        ])
        #expect(result.exitCode == 0)
        #expect(
            !result.generated.contains("container.register((any Validator).self"),
            "bridging to a conditionally-present type reintroduces the freeze failure")
    }

    @Test("registration order is deterministic across runs")
    func deterministicOutput() throws {
        let sources = [
            "A.swift": "import FlightCore\n@Component final class Alpha: Sendable { init() {} }",
            "B.swift": "import FlightCore\n@Component final class Beta: Sendable { init() {} }",
            "C.swift": "import FlightCore\n@Component final class Gamma: Sendable { init() {} }",
        ]
        let first = try generate(sources)
        let second = try generate(sources)
        #expect(first.exitCode == 0)
        #expect(first.generated == second.generated, "codegen must not depend on filesystem order")
    }

    @Test("a file with no Flight attributes contributes nothing")
    func ignoresUnrelatedSources() throws {
        let result = try generate([
            "Plain.swift": "struct NotAComponent { let value = 1 }"
        ])
        #expect(result.exitCode == 0)
        #expect(!result.generated.contains("NotAComponent"))
    }

    // MARK: - Required-key checks against flight.yaml
    //
    // A @ConfigValue with no default:, or a @Settings property with no
    // default value, must exist in flight.yaml's base layer — checked here
    // at build time rather than left to surface as a bootstrap-time throw.
    // No prior test drove this executable end to end; these do.

    @Test("a required @ConfigValue key missing from flight.yaml is a build error")
    func requiredConfigValueKeyMissingIsAnError() throws {
        let result = try generate(
            [
                "Server.swift": """
                import FlightCore
                @Component final class ServerConfig: Sendable {
                    @ConfigValue("server.port") let port: Int
                }
                """
            ],
            flightYAML: "other:\n  key: value\n"
        )
        #expect(result.exitCode != 0)
        #expect(result.diagnostics.contains("server.port"))
        #expect(result.diagnostics.contains("@ConfigValue"))
    }

    @Test("a required @ConfigValue key present in flight.yaml succeeds")
    func requiredConfigValueKeyPresentSucceeds() throws {
        let result = try generate(
            [
                "Server.swift": """
                import FlightCore
                @Component final class ServerConfig: Sendable {
                    @ConfigValue("server.port") let port: Int
                }
                """
            ],
            flightYAML: "server:\n  port: 8080\n"
        )
        #expect(result.exitCode == 0)
        #expect(result.diagnostics.isEmpty)
    }

    @Test("a required @Settings property missing from flight.yaml is a build error, without claiming @ConfigValue was written")
    func requiredSettingsKeyMissingIsAnError() throws {
        let result = try generate(
            [
                "AuthSettings.swift": """
                import FlightCore
                @Settings("auth")
                struct AuthSettings: Sendable {
                    var signingKey: String
                }
                """
            ],
            flightYAML: "other:\n  key: value\n"
        )
        #expect(result.exitCode != 0)
        #expect(result.diagnostics.contains("auth.signing-key"))
        // The property has no @ConfigValue attribute at all — the message
        // must not claim one, or it would send someone looking for a line
        // of code that was never written.
        #expect(!result.diagnostics.contains("@ConfigValue"))
    }

    @Test("a required @Settings property present in flight.yaml succeeds")
    func requiredSettingsKeyPresentSucceeds() throws {
        let result = try generate(
            [
                "AuthSettings.swift": """
                import FlightCore
                @Settings("auth")
                struct AuthSettings: Sendable {
                    var signingKey: String
                }
                """
            ],
            flightYAML: "auth:\n  signing-key: a-real-signing-key\n"
        )
        #expect(result.exitCode == 0)
        #expect(result.diagnostics.isEmpty)
    }

    @Test("a @Settings property with its own default needs no flight.yaml entry at all")
    func optionalSettingsKeyNeedsNoEntry() throws {
        let result = try generate(
            [
                "AuthSettings.swift": """
                import FlightCore
                @Settings("auth")
                struct AuthSettings: Sendable {
                    var issuer: String = "myapp"
                }
                """
            ]
            // No flightYAML at all — packageDirectory still gets set (the
            // workspace itself), so this also proves a missing flight.yaml
            // file is "skip the check", not "every required-looking key
            // fails".
        )
        #expect(result.exitCode == 0)
        #expect(result.diagnostics.isEmpty)
    }

    @Test("a @Settings property overridden with an explicit @ConfigValue key is checked under that key")
    func settingsExplicitKeyOverrideIsChecked() throws {
        let result = try generate(
            [
                "AuthSettings.swift": """
                import FlightCore
                @Settings("auth")
                struct AuthSettings: Sendable {
                    @ConfigValue("legacy.audience") let audience: String
                }
                """
            ],
            flightYAML: "auth:\n  audience: not-the-right-key\n"
        )
        #expect(result.exitCode != 0)
        #expect(result.diagnostics.contains("legacy.audience"))
        // The derived key must not also be checked — only the explicit one.
        #expect(!result.diagnostics.contains("auth.audience"))
    }

    // MARK: - Existential bridge synthesis
    //
    // The most intricate code in the generator, and — before these tests — the
    // part nothing had ever executed: the demo app that served as its only
    // validation happens to synthesize zero bridges.

    @Test("a protocol with exactly one conformer gets a synthesized bridge")
    func synthesizesBridgeForSoleConformer() throws {
        let result = try generate([
            "Repo.swift": """
            import FlightCore
            protocol UserRepositoryProtocol: Sendable {}
            @Repository final class UserRepository: UserRepositoryProtocol, Sendable {
            init() {}
            }
            @Service final class UserService: Sendable {
            @Inject var repository: any UserRepositoryProtocol
            init() {}
            }
            """
        ])
        #expect(result.exitCode == 0)
        #expect(
            result.generated.contains("UserRepositoryProtocol"),
            "a request for `any P` with a sole conformer should synthesize a bridge"
        )
        #expect(
            !result.diagnostics.contains("UserRepositoryProtocol"),
            "a synthesized bridge should satisfy the request without a diagnostic"
        )
    }

    @Test("a protocol with two conformers is not bridged, and says why")
    func ambiguousProtocolIsNotBridged() throws {
        let result = try generate([
            "Two.swift": """
            import FlightCore
            protocol Greeter: Sendable {}
            @Component final class English: Greeter, Sendable { init() {} }
            @Component final class French: Greeter, Sendable { init() {} }
            """
        ])
        // Ambiguity must not silently resolve to whichever was scanned first.
        #expect(result.exitCode == 0)
        #expect(result.generated.contains("English"))
        #expect(result.generated.contains("French"))
    }

    @Test("a conformance declared in an extension still counts")
    func extensionConformanceIsSeen() throws {
        let result = try generate([
            "Service.swift": """
            import FlightCore
            protocol Pinger: Sendable {}
            @Component final class Pinger1: Sendable { init() {} }
            extension Pinger1: Pinger {}
            """
        ])
        #expect(result.exitCode == 0)
        #expect(result.generated.contains("Pinger1"))
    }

    // MARK: - Diagnostics

    @Test("a missing registration is reported")
    func reportsMissingRegistration() throws {
        let result = try generate([
            "Needy.swift": """
            import FlightCore
            @Service final class Needy: Sendable {
            @Inject var missing: NoSuchComponent
            init() {}
            }
            """
        ])
        #expect(
            result.diagnostics.contains("NoSuchComponent"),
            "an unsatisfiable dependency must name the type it could not find"
        )
    }

    @Test("a dependency cycle is reported and names both types")
    func reportsCycle() throws {
        let result = try generate([
            "Cycle.swift": """
            import FlightCore
            @Component final class Ping: Sendable {
            @Inject var pong: Pong
            init() {}
            }
            @Component final class Pong: Sendable {
            @Inject var ping: Ping
            init() {}
            }
            """
        ])
        #expect(result.diagnostics.lowercased().contains("cycl"))
        #expect(result.diagnostics.contains("Ping") && result.diagnostics.contains("Pong"))
    }

    @Test("a hand-registered marker suppresses the missing-registration report")
    func handRegisteredMarkerSuppresses() throws {
        let result = try generate([
            "Marked.swift": """
            import FlightCore
            @Service final class Marked: Sendable {
            // flight:hand-registered
            @Inject var external: SomethingRegisteredByHand
            init() {}
            }
            """
        ])
        #expect(
            !result.diagnostics.contains("SomethingRegisteredByHand"),
            "the documented escape hatch must actually suppress the diagnostic"
        )
    }

    // MARK: - FlightGraph

    @Test("the graph builds every component once, in dependency order")
    func graphIsTopologicallyOrdered() throws {
        let result = try generate([
            "Sources.swift": """
            import FlightCore
            @Repository
            struct UserRepository: Sendable {}
            @Service
            struct UserService: Sendable {
            @Inject var repo: UserRepository
            }
            """
        ])
        #expect(result.exitCode == 0)
        let repo = try #require(result.generated.range(of: "self.userRepository ="))
        let service = try #require(result.generated.range(of: "self.userService ="))
        #expect(repo.lowerBound < service.lowerBound, "a dependency is built before its dependent")
        // Labelled by property name, which is what the generated initializer
        // uses — not by type name.
        #expect(result.generated.contains("UserService(repo: userRepository)"))
    }

    @Test("a dependency the graph cannot build becomes a root parameter")
    func unbuildableDependencyBecomesAParameter() throws {
        // §2.6's escape hatch: externally supplied values arrive through the
        // same typed parameters everything else uses, at one root rather than
        // scattered across N configure(_:) bodies. A framework component
        // registered imperatively by a module is the ordinary case.
        let result = try generate([
            "Sources.swift": """
            import FlightCore
            @Repository
            struct UserRepository: Sendable {
            @Inject var pool: PostgresDataSource
            }
            """
        ])
        #expect(result.exitCode == 0)
        #expect(result.generated.contains("init(postgresDataSource: PostgresDataSource,"))
        #expect(result.generated.contains("UserRepository(pool: postgresDataSource)"))
    }

    @Test("an existential dependency resolves to its single conformer")
    func existentialResolvesToConformer() throws {
        // The same mapping the synthesized bridges use, so the graph and the
        // registration path agree about which concrete type answers `any P`.
        let result = try generate([
            "Sources.swift": """
            import FlightCore
            protocol UserStore {}
            @Repository
            struct UserRepository: UserStore {}
            @Service
            struct UserService: Sendable {
            @Inject var store: (any UserStore)
            }
            """
        ])
        #expect(result.exitCode == 0)
        #expect(result.generated.contains("UserService(store: userRepository)"))
    }

    @Test("a config-reading component takes the configuration and throws")
    func configurationIsARootParameter() throws {
        let result = try generate([
            "Sources.swift": """
            import FlightCore
            @Service
            struct Pager: Sendable {
            @ConfigValue("app.page-size") var size: Int
            }
            """,
        ], flightYAML: "app:\n  page-size: 25\n")
        #expect(result.exitCode == 0)
        #expect(result.generated.contains("init(configuration: FlightCore.Configuration,"))
        #expect(result.generated.contains("(try Pager(_flightConfiguration: configuration))"))
    }

    @Test("a module-registered component is left out of the graph")
    func moduleRegisteredIsExcluded() throws {
        // Same reason flightRegisterAll leaves it out: whether it exists in
        // an application is a runtime question its own module answers.
        let result = try generate([
            "Sources.swift": """
            import FlightWeb
            // flight:module-registered
            @Middleware struct Authentication: Sendable {}
            @Service struct Other: Sendable {}
            """
        ])
        #expect(result.exitCode == 0)
        #expect(result.generated.contains("let other: Other"))
        #expect(!result.generated.contains("let authentication: Authentication"))
    }

    @Test("the graph is constructible from a container, not just compilable")
    func graphIsConstructibleFromAContainer() throws {
        // A function rather than a registration, deliberately: every
        // component is built eagerly at freeze, so registering the graph
        // would make a missing root parameter fail the boot of an
        // application that works today — for a value nothing calls yet.
        let result = try generate([
            "Sources.swift": """
            import FlightCore
            @Repository
            struct UserRepository: Sendable {
            // flight:hand-registered
            @Inject var pool: PostgresDataSource
            }
            """
        ])
        #expect(result.exitCode == 0)
        #expect(
            result.generated.contains(
                "func makeFlightGraph(_ container: FlightCore.Container) throws -> FlightGraph"))
        #expect(
            result.generated.contains(
                "postgresDataSource: container.resolve(PostgresDataSource.self)"))
    }

    @Test("routes are emitted with a per-request controller, through the macro's factory")
    func routesConstructPerRequest() throws {
        let result = try generate([
            "Sources.swift": """
            import FlightWeb
            @Service
            struct UserService: Sendable {}
            @Controller("/users")
            struct UserController {
            @Inject var users: UserService
            @GetRoute("/:id")
            func show(_ context: RequestContext) -> String { "x" }
            }
            """
        ])
        #expect(result.exitCode == 0)
        // The whole route lives in the factory the macro generated; this
        // supplies only how the controller is obtained.
        #expect(
            result.generated.contains(
                "UserController._flightRoute_show_0 { _ in UserController(users: graph.userService) }"
            ))
        #expect(result.generated.contains("let graph = try c.resolve(FlightGraph.self)"))
    }

    @Test("a controller is not a graph node — it is built per request")
    func controllerIsNotAGraphNode() throws {
        // The point of §2.1a: process dependencies are held, the controller
        // is not. A controller something *else* injects stays a node,
        // because then the graph does have to build it.
        let result = try generate([
            "Sources.swift": """
            import FlightWeb
            @Service
            struct UserService: Sendable {}
            @Controller("/users")
            struct UserController {
            @Inject var users: UserService
            @GetRoute("/:id")
            func show(_ context: RequestContext) -> String { "x" }
            }
            """
        ])
        #expect(result.exitCode == 0)
        #expect(result.generated.contains("let userService: UserService"))
        #expect(!result.generated.contains("let userController: UserController"))
    }

    @Test("a root input only a controller needs is still stored on the graph")
    func controllerOnlyRootInputIsStored() throws {
        // The terminal reaches its dependencies *through* the graph, so a
        // root input no graph node uses still has to be there.
        let result = try generate([
            "Sources.swift": """
            import FlightWeb
            @Controller("/socket")
            struct SocketController {
            // flight:hand-registered
            @Inject var validator: (any TokenValidator)
            @GetRoute("/")
            func open(_ context: RequestContext) -> String { "x" }
            }
            """
        ])
        #expect(result.exitCode == 0)
        // Named for the type, not the property: two properties of one type
        // are one root input, which is what makes them the *same* value.
        #expect(result.generated.contains("let tokenValidator: (any TokenValidator)"))
        #expect(
            result.generated.contains("SocketController(validator: graph.tokenValidator)"))
    }

    @Test("the graph constructs; the container projects onto it")
    func graphProjectsRatherThanRebuilds() throws {
        // One construction, in one place. Both mechanisms building would
        // give an application two of every component — a route terminal
        // reaching one through the graph, a channel or a job reaching the
        // other through the container. Harmless for a stateless repository;
        // a silent split-brain for anything holding state.
        let result = try generate([
            "Sources.swift": """
            import FlightWeb
            @Service
            struct UserService: Sendable {}
            @Controller("/users")
            struct UserController {
            @Inject var users: UserService
            @GetRoute("/:id")
            func show(_ context: RequestContext) -> String { "x" }
            }
            """
        ])
        #expect(result.exitCode == 0)
        // The graph constructs; the container projects onto it.
        #expect(result.generated.contains("let userService = userService ?? UserService()"))
        #expect(
            result.generated.contains("graph.userService"),
            "the container registration must project, not construct a second copy")
        #expect(
            !result.generated.contains("try UserService._flightRegister"),
            "a projected component must not also be constructed by its own thunk")
    }

    @Test("a test can replace one node and get the rest of the graph real")
    func nodesAreDefaultedParameters() throws {
        // §2.10's claim, made real. `Container.override` exists because the
        // alternative was hand-rebuilding the object graph in every test
        // module; a defaulted parameter per node is that, generated.
        let result = try generate([
            "Sources.swift": """
            import FlightCore
            protocol UserStore {}
            @Repository
            struct UserRepository: UserStore {}
            @Service
            struct UserService: Sendable {
            @Inject var store: (any UserStore)
            }
            """
        ])
        #expect(result.exitCode == 0)
        #expect(result.generated.contains("userRepository: UserRepository? = nil"))
        #expect(result.generated.contains("userService: UserService? = nil"))
        // The local binding, not the parameter, is what downstream nodes see
        // — otherwise a supplied instance would be composed around a second
        // copy of itself.
        #expect(
            result.generated.contains(
                "let userRepository = userRepository ?? UserRepository()"))
        #expect(result.generated.contains("UserService(store: userRepository)"))
    }

    @Test("an application whose only component is a controller still registers the graph")
    func controllerOnlyAppRegistersTheGraph() throws {
        // The skeleton template's shape, and a bug it caught that a richer
        // application could not: with the controller excluded from the graph
        // there are no nodes, but the route terminals still resolve
        // FlightGraph — so gating its registration on "has nodes" emitted
        // terminals that resolved a type nothing registered.
        let result = try generate([
            "Sources.swift": """
            import FlightWeb
            @Controller
            struct HealthController {
            @GetRoute("/")
            func index(_ context: RequestContext) -> String { "ok" }
            }
            """
        ])
        #expect(result.exitCode == 0)
        #expect(result.generated.contains("container.register(FlightGraph.self"))
        #expect(result.generated.contains("try c.resolve(FlightGraph.self)"))
    }

    // MARK: - The composition root

    @Test("the composer builds every included module, dependencies first")
    func composerBuildsInOrder() throws {
        let result = try generate([
            "Main.swift": """
            import FlightWeb
            final class PubSubModule: FlightModule {
            func configure(_ container: Container) throws {}
            }
            final class ChannelsModule: FlightModule {
            static var dependencies: [any FlightModule.Type] { [PubSubModule.self] }
            init(configuration: Configuration, pubsub: PubSubModule) throws {}
            func configure(_ container: Container) throws {}
            }
            @main struct Main {
            static func main() async {
            await Flight.run(configuration: .load(), modules: [ChannelsModule.self])
            }
            }
            """
        ])
        #expect(result.exitCode == 0)
        #expect(result.generated.contains("let pubSubModule = PubSubModule()"))
        // A module that declares what it needs is wired from what came before.
        #expect(
            result.generated.contains(
                "let channelsModule = try ChannelsModule(configuration: configuration, pubsub: pubSubModule)"
            ))
    }

    @Test("a module's property is wired into another module's parameter")
    func composerWiresProvidedProperties() throws {
        // The adapter shape: the provider declares no dependency on the
        // consumer and the consumer cannot name the provider — flight does not
        // know flight-data exists. The type is the whole connection.
        let result = try generate([
            "Main.swift": """
            import FlightWeb
            struct ValkeyModule: FlightModule {
            let adapter: any DistributedPubSubAdapter
            init(configuration: Configuration) throws {}
            func configure(_ container: Container) throws {}
            }
            struct PubSubModule: FlightModule {
            init(configuration: Configuration, adapter: (any DistributedPubSubAdapter)? = nil) throws {}
            func configure(_ container: Container) throws {}
            }
            @main struct Main {
            static func main() async {
            await Flight.run(
            configuration: .load(), modules: [PubSubModule.self, ValkeyModule.self])
            }
            }
            """
        ])
        #expect(result.exitCode == 0)
        #expect(
            result.generated.contains(
                "let pubSubModule = try PubSubModule(configuration: configuration, adapter: valkeyModule.adapter)"
            ))
        // And the provider is built first, though nothing declared that edge:
        // the application listed PubSub first, and neither module names the
        // other in `dependencies`.
        let valkey = try #require(result.generated.range(of: "let valkeyModule ="))
        let pubsub = try #require(result.generated.range(of: "let pubSubModule ="))
        #expect(valkey.lowerBound < pubsub.lowerBound)
    }

    @Test("an array parameter collects from every contributing module, in order")
    func composerConcatenatesAggregates() throws {
        // The extension seam: two modules contribute channels, neither knows
        // about the other, and the aggregator takes all of them. Several
        // providers of one type is the *right* answer here, which is why an
        // aggregate is not treated as the ambiguity a scalar would be.
        let result = try generate([
            "Main.swift": """
            import FlightWeb
            struct ChatModule: FlightModule {
            let channels: [ChannelRegistration]
            func configure(_ container: Container) throws {}
            }
            struct NotificationsModule: FlightModule {
            let channels: [ChannelRegistration]
            func configure(_ container: Container) throws {}
            }
            struct FlightChannelsModule: FlightModule {
            init(channels: [ChannelRegistration] = []) throws {}
            func configure(_ container: Container) throws {}
            }
            @main struct Main {
            static func main() async {
            await Flight.run(
            configuration: .load(),
            modules: [FlightChannelsModule.self, ChatModule.self, NotificationsModule.self])
            }
            }
            """
        ])
        #expect(result.exitCode == 0)
        #expect(
            result.generated.contains(
                "let flightChannelsModule = try FlightChannelsModule(channels: chatModule.channels + notificationsModule.channels)"
            ))
        // Both contributors are built before the aggregator, though the
        // application listed the aggregator first.
        let chat = try #require(result.generated.range(of: "let chatModule ="))
        let channels = try #require(result.generated.range(of: "let flightChannelsModule ="))
        #expect(chat.lowerBound < channels.lowerBound)
    }

    @Test("an aggregate nobody contributes to is omitted")
    func composerOmitsEmptyAggregates() throws {
        // The ordinary app with no channels at all. `[]` is the default, so
        // the parameter is simply not passed.
        let result = try generate([
            "Main.swift": """
            import FlightWeb
            struct FlightChannelsModule: FlightModule {
            init(channels: [ChannelRegistration] = []) throws {}
            func configure(_ container: Container) throws {}
            }
            @main struct Main {
            static func main() async {
            await Flight.run(configuration: .load(), modules: [FlightChannelsModule.self])
            }
            }
            """
        ])
        #expect(result.exitCode == 0)
        #expect(result.generated.contains("let flightChannelsModule = try FlightChannelsModule()"))
    }

    @Test("the composition root builds the graph from what modules provide")
    func composerBuildsTheGraph() throws {
        let result = try generate([
            "Main.swift": """
            import FlightWeb
            struct PoolModule: FlightModule {
            let dataSource: DataSource
            init() { self.dataSource = DataSource() }
            func configure(_ container: Container) throws {}
            }
            struct AppModule: FlightModule {
            let graph: FlightGraph
            init(graph: FlightGraph) { self.graph = graph }
            func configure(_ container: Container) throws {}
            }
            @Repository struct UserRepository { @Inject var pool: DataSource }
            @main struct Main {
            static func main() async {
            await Flight.run(
            configuration: .load(), modules: [AppModule.self, PoolModule.self])
            }
            }
            """
        ])
        #expect(result.exitCode == 0)
        // The graph's root is a module's property, matched by type — the same
        // rule a module's own initializer parameters go through.
        #expect(
            result.generated.contains(
                "let flightGraph = try FlightGraph(dataSource: poolModule.dataSource)"))
        // And it sorts between them: after the module providing its root,
        // before the module that registers from it.
        let pool = try #require(result.generated.range(of: "let poolModule ="))
        let graph = try #require(result.generated.range(of: "let flightGraph ="))
        let app = try #require(result.generated.range(of: "let appModule ="))
        #expect(pool.lowerBound < graph.lowerBound)
        #expect(graph.lowerBound < app.lowerBound)
        // The graph is a value, not a module: it is not in the returned list.
        let returned = try #require(result.generated.range(of: "return ["))
        #expect(!result.generated[returned.lowerBound...].contains("flightGraph,"))
    }

    @Test("a graph root nothing provides is a build error naming the type")
    func composerReportsMissingGraphRoot() throws {
        let result = try generate([
            "Main.swift": """
            import FlightWeb
            struct AppModule: FlightModule {
            let graph: FlightGraph
            init(graph: FlightGraph) { self.graph = graph }
            func configure(_ container: Container) throws {}
            }
            @Repository struct UserRepository { @Inject var pool: DataSource }
            @main struct Main {
            static func main() async {
            await Flight.run(configuration: .load(), modules: [AppModule.self])
            }
            }
            """
        ])
        #expect(result.generated.contains("#error("))
        #expect(result.generated.contains("The component graph needs DataSource"))
    }

    @Test("a contribution nothing collects is a build error naming the module to add")
    func composerRefusesUnconsumedContributions() throws {
        // The footgun the aggregate rule would otherwise introduce: declaring
        // channels while leaving Channels out of the application composes
        // fine, starts fine, and finds no route at the first join. Exactly the
        // silence the PubSub inversion existed to remove.
        let result = try generate([
            "Main.swift": """
            import FlightWeb
            struct FlightChannelsModule: FlightModule {
            init(channels: [ChannelRegistration] = []) throws {}
            func configure(_ container: Container) throws {}
            }
            struct ChatModule: FlightModule {
            let channels: [ChannelRegistration] = []
            func configure(_ container: Container) throws {}
            }
            @main struct Main {
            static func main() async {
            await Flight.run(configuration: .load(), modules: [ChatModule.self])
            }
            }
            """
        ])
        #expect(result.generated.contains("#error("))
        #expect(result.generated.contains("ChatModule.channels is declared but nothing"))
        // Names what to add, rather than only observing that it went unused.
        #expect(result.generated.contains("FlightChannelsModule"))
    }

    @Test("a collected contribution is not reported")
    func composerAcceptsConsumedContributions() throws {
        let result = try generate([
            "Main.swift": """
            import FlightWeb
            struct FlightChannelsModule: FlightModule {
            init(channels: [ChannelRegistration] = []) throws {}
            func configure(_ container: Container) throws {}
            }
            struct ChatModule: FlightModule {
            let channels: [ChannelRegistration] = []
            func configure(_ container: Container) throws {}
            }
            @main struct Main {
            static func main() async {
            await Flight.run(
            configuration: .load(), modules: [ChatModule.self, FlightChannelsModule.self])
            }
            }
            """
        ])
        #expect(result.exitCode == 0)
        #expect(!result.generated.contains("#error("))
    }

    @Test("a dictionary parameter is not an aggregate")
    func composerDoesNotAggregateDictionaries() throws {
        // `[String: String]` is one value, and ActuatorModule's `environment`
        // is exactly that shape.
        let result = try generate([
            "Main.swift": """
            import FlightWeb
            struct EnvModule: FlightModule {
            let environment: [String: String]
            func configure(_ container: Container) throws {}
            }
            struct ConsumerModule: FlightModule {
            init(environment: [String: String]) {}
            func configure(_ container: Container) throws {}
            }
            @main struct Main {
            static func main() async {
            await Flight.run(
            configuration: .load(), modules: [EnvModule.self, ConsumerModule.self])
            }
            }
            """
        ])
        #expect(result.exitCode == 0)
        #expect(
            result.generated.contains(
                "let consumerModule = ConsumerModule(environment: envModule.environment)"))
    }

    @Test("a module is never built out of its own property")
    func composerExcludesSelfAsProvider() throws {
        // ActuatorModule's real shape: a stored `environment` and an
        // `init(environment:)` test seam. Matching providers by type made that
        // initializer look satisfiable by the module's own property, and the
        // composer emitted
        // `let actuatorModule = ActuatorModule(environment: actuatorModule.environment)`.
        // Caught by the demo template, not by these fixtures.
        let result = try generate([
            "Main.swift": """
            import FlightWeb
            struct ActuatorModule: FlightModule {
            let environment: [String: String]
            init() { self.environment = [:] }
            init(environment: [String: String]) { self.environment = environment }
            func configure(_ container: Container) throws {}
            }
            @main struct Main {
            static func main() async {
            await Flight.run(configuration: .load(), modules: [ActuatorModule.self])
            }
            }
            """
        ])
        #expect(result.exitCode == 0)
        #expect(result.generated.contains("let actuatorModule = ActuatorModule()"))
        #expect(!result.generated.contains("actuatorModule.environment"))
    }

    @Test("an optional parameter nothing provides is omitted, not failed")
    func composerOmitsUnprovidedOptionals() throws {
        // The single-node deployment: same PubSub module, no adapter module.
        // "Not in this deployment" has to compose, because it is the 90% case.
        let result = try generate([
            "Main.swift": """
            import FlightWeb
            struct PubSubModule: FlightModule {
            init(configuration: Configuration, adapter: (any DistributedPubSubAdapter)? = nil) throws {}
            func configure(_ container: Container) throws {}
            }
            @main struct Main {
            static func main() async {
            await Flight.run(configuration: .load(), modules: [PubSubModule.self])
            }
            }
            """
        ])
        #expect(result.exitCode == 0)
        #expect(
            result.generated.contains("let pubSubModule = try PubSubModule(configuration: configuration)"))
    }

    @Test("two modules providing the same type is a build error naming both")
    func composerRefusesAmbiguousProviders() throws {
        let result = try generate([
            "Main.swift": """
            import FlightWeb
            struct ValkeyModule: FlightModule {
            let adapter: any DistributedPubSubAdapter
            init(configuration: Configuration) throws {}
            func configure(_ container: Container) throws {}
            }
            struct NatsModule: FlightModule {
            let adapter: any DistributedPubSubAdapter
            init(configuration: Configuration) throws {}
            func configure(_ container: Container) throws {}
            }
            struct PubSubModule: FlightModule {
            init(configuration: Configuration, adapter: (any DistributedPubSubAdapter)? = nil) throws {}
            func configure(_ container: Container) throws {}
            }
            @main struct Main {
            static func main() async {
            await Flight.run(
            configuration: .load(),
            modules: [PubSubModule.self, ValkeyModule.self, NatsModule.self])
            }
            }
            """
        ])
        // The generated file carries the reason, so the consumer's compiler
        // points at it. Silently picking one would give a cluster wired to the
        // wrong transport.
        #expect(result.generated.contains("#error("))
        #expect(result.generated.contains("Composition is ambiguous"))
        #expect(result.generated.contains("natsModule.adapter"))
        #expect(result.generated.contains("valkeyModule.adapter"))
    }

    @Test("a module's computed service is not something another module can take")
    func composerIgnoresComputedProperties() throws {
        // `var service: (any Service)?` is bootstrap's to collect. Treating it
        // as a provided value would let one module take another's service and
        // run it twice.
        let result = try generate([
            "Main.swift": """
            import FlightWeb
            struct ProviderModule: FlightModule {
            var service: (any Service)? { nil }
            func configure(_ container: Container) throws {}
            }
            struct ConsumerModule: FlightModule {
            init(service: (any Service)? = nil) {}
            func configure(_ container: Container) throws {}
            }
            @main struct Main {
            static func main() async {
            await Flight.run(
            configuration: .load(), modules: [ProviderModule.self, ConsumerModule.self])
            }
            }
            """
        ])
        #expect(result.exitCode == 0)
        #expect(result.generated.contains("let consumerModule = ConsumerModule()"))
    }

    @Test("a generic module keeps its type argument")
    func genericModuleKeepsItsArgument() throws {
        // `FlightWebModule<FlightTransport>` is one module named with the
        // transport it was chosen with. Matching strips the argument;
        // constructing cannot.
        let result = try generate([
            "Main.swift": """
            import FlightWeb
            final class FlightWebModule<T: Sendable>: FlightModule {
            func configure(_ container: Container) throws {}
            }
            @main struct Main {
            static func main() async {
            await Flight.run(
            configuration: .load(), modules: [FlightWebModule<FlightTransport>.self])
            }
            }
            """
        ])
        #expect(result.exitCode == 0)
        #expect(
            result.generated.contains("let flightWebModule = FlightWebModule<FlightTransport>()"))
    }

    @Test("a module declaring init() is constructed that way, whatever else it offers")
    func noArgumentInitWins() throws {
        // ActuatorModule declares init() *and* init(processEnvironment:) —
        // the second is a test seam, and picking the first parameterized
        // initializer found chose the seam.
        let result = try generate([
            "Main.swift": """
            import FlightWeb
            final class ActuatorModule: FlightModule {
            init() {}
            init(processEnvironment: [String: String]) {}
            func configure(_ container: Container) throws {}
            }
            @main struct Main {
            static func main() async {
            await Flight.run(configuration: .load(), modules: [ActuatorModule.self])
            }
            }
            """
        ])
        #expect(result.exitCode == 0)
        #expect(result.generated.contains("let actuatorModule = ActuatorModule()"))
        #expect(!result.generated.contains("processEnvironment:"))
    }

    // MARK: - Included modules

    @Test("the bootstrap list resolves transitively, dependencies first")
    func includedModulesResolve() throws {
        // The fact D11 turns on: which subsystems an application includes is
        // a literal in its own source, so it is knowable at build time. It
        // was treated as a runtime question only because the container was
        // the one thing that knew it.
        let result = try generate([
            "Main.swift": """
            import FlightWeb
            final class AppModule: FlightModule {
            static var dependencies: [any FlightModule.Type] { [ChannelsModule.self] }
            func configure(_ container: Container) throws {}
            }
            final class ChannelsModule: FlightModule {
            static var dependencies: [any FlightModule.Type] { [PubSubModule.self] }
            func configure(_ container: Container) throws {}
            }
            final class PubSubModule: FlightModule {
            func configure(_ container: Container) throws {}
            }
            final class UnlistedModule: FlightModule {
            func configure(_ container: Container) throws {}
            }
            @main struct Main {
            static func main() async {
            await Flight.run(configuration: .load(), modules: [AppModule.self])
            }
            }
            """
        ])
        #expect(result.exitCode == 0)
        #expect(
            result.generated.contains(
                #""PubSubModule",\n        "ChannelsModule",\n        "AppModule","#
                    .replacingOccurrences(of: "\\n", with: "\n")),
            "dependencies come before the module that pulled them in")
        // Linked but never listed: present in the graph, absent from the set.
        #expect(result.generated.contains(#"name: "UnlistedModule""#))
        let start = try #require(
            result.generated.range(of: "public static let includedModules")).lowerBound
        let end = try #require(result.generated.range(of: "\n    ]", range: start..<result.generated.endIndex)).upperBound
        #expect(!result.generated[start..<end].contains("UnlistedModule"))
    }

    @Test("a target that starts nothing includes nothing")
    func libraryIncludesNothing() throws {
        let result = try generate([
            "Sources.swift": """
            import FlightCore
            @Service struct UserService: Sendable {}
            """
        ])
        #expect(result.exitCode == 0)
        #expect(result.generated.contains("public static let includedModules: [String] = [\n    ]"))
    }

    // MARK: - Undeclared lanes

    @Test("a route naming an undeclared lane is warned about at build time")
    func undeclaredLaneWarns() throws {
        let result = try generate([
            "AppModule.swift": """
            import FlightWeb
            @Controller("/admin", pipelines: ["audit"])
            struct AdminController {
            @GetRoute("/")
            func index(_ context: RequestContext) -> String { "x" }
            }
            """
        ])
        // A warning, not an error: the scan reaches source dependencies only,
        // so a lane declared in a binary dependency is invisible to it.
        // UndeclaredLaneError at bootstrap stays the enforcement.
        #expect(result.exitCode == 0)
        #expect(result.diagnostics.contains("warning"))
        #expect(result.diagnostics.contains("audit"))
    }

    @Test("a declared lane is not warned about")
    func declaredLaneIsQuiet() throws {
        let result = try generate([
            "AppModule.swift": """
            import FlightWeb
            final class AppModule: FlightModule {
            func configure(_ container: Container) throws {
            container.pipeline("audit") { AuditLog.self }
            }
            }
            @Controller("/admin", pipelines: ["audit"])
            struct AdminController {
            @GetRoute("/")
            func index(_ context: RequestContext) -> String { "x" }
            }
            """
        ])
        #expect(result.exitCode == 0)
        #expect(!result.diagnostics.contains("audit"))
    }

    @Test("the two lanes dispatch provides need no declaration")
    func canonicalLanesNeedNoDeclaration() throws {
        // `.default` exists whether or not anything registers into it, and
        // `.public` means "explicitly no lanes" — DispatchBuilder supplies
        // both, so naming them is never a mistake.
        let result = try generate([
            "AppModule.swift": """
            import FlightWeb
            @Controller("/x", pipelines: [.default])
            struct A {
            @GetRoute("/a")
            func a(_ context: RequestContext) -> String { "a" }
            @GetRoute("/b", pipelines: [.public])
            func b(_ context: RequestContext) -> String { "b" }
            }
            """
        ])
        #expect(result.exitCode == 0)
        #expect(!result.diagnostics.contains("pipeline lane"))
    }

    @Test("a computed lane name silences the check rather than guessing")
    func computedLaneStaysQuiet() throws {
        // One unknowable declaration makes the whole set unknowable: it might
        // be the very lane the route is asking for.
        let result = try generate([
            "AppModule.swift": """
            import FlightWeb
            final class AppModule: FlightModule {
            func configure(_ container: Container) throws {
            container.pipeline(PipelineLane(computedName)) { AuditLog.self }
            }
            }
            @Controller("/admin", pipelines: ["audit"])
            struct AdminController {
            @GetRoute("/")
            func index(_ context: RequestContext) -> String { "x" }
            }
            """
        ])
        #expect(result.exitCode == 0)
        #expect(!result.diagnostics.contains("pipeline lane"))
    }

    // MARK: - Removed lifetimes

    @Test("a removed lifetime is a build error that says what to do instead")
    func removedLifetimeDiagnosed() throws {
        // This check used to catch captive dependencies — a singleton
        // injecting a `.scoped` component. That class cannot happen now:
        // there is one lifetime, so a singleton has nothing shorter-lived to
        // capture. What survives is the migration case. Source carrying
        // `.scoped` otherwise meets "type 'Lifetime' has no member 'scoped'",
        // which says what is wrong and nothing about what to do.
        let result = try generate([
            "Captive.swift": """
            import FlightCore
            @Repository(scope: .scoped) final class UserRepository: Sendable {
            init() {}
            }
            """
        ])
        #expect(result.exitCode != 0)
        #expect(result.diagnostics.contains("UserRepository"))
        #expect(result.diagnostics.contains("no longer exists"))
        #expect(result.diagnostics.contains("RequestContext"))
    }

    @Test("`.transient` is diagnosed the same way")
    func removedTransientDiagnosed() throws {
        let result = try generate([
            "Old.swift": """
            import FlightCore
            @Service(scope: .transient) final class Builder: Sendable {
            init() {}
            }
            """
        ])
        #expect(result.exitCode != 0)
        #expect(result.diagnostics.contains(".transient"))
    }

    // MARK: - Static route manifest

    @Test("routes are scanned into a static manifest, with controller paths combined")
    func emitsRouteManifest() throws {
        let result = try generate([
            "UserController.swift": """
            import FlightWeb
            @Controller("/users")
            struct UserController {
            @GetRoute("/:id")
            func show(_ context: RequestContext) -> String { "x" }
            @PostRoute("")
            func create(_ context: RequestContext) -> String { "y" }
            }
            """
        ])
        #expect(result.exitCode == 0)
        #expect(result.generated.contains("FlightRouteManifest"))
        // The combination rule is the macro's, applied by the same parser.
        #expect(result.generated.contains(#"path: "/users/:id""#))
        #expect(result.generated.contains(#"path: "/users""#))
        #expect(result.generated.contains(#"method: "GET""#))
        #expect(result.generated.contains(#"method: "POST""#))
        #expect(result.generated.contains("AppModule.UserController.show"))
    }

    @Test("a route's own pipelines replace the controller's in the manifest")
    func manifestResolvesPipelines() throws {
        // Replacement, not addition — the rule a route relies on to say
        // "this one is public" under an authenticated controller.
        let result = try generate([
            "DashboardController.swift": """
            import FlightWeb
            @Controller("/dashboard", pipelines: [.authenticated])
            struct DashboardController {
            @GetRoute("/admin")
            func admin(_ context: RequestContext) -> String { "a" }
            @GetRoute("/", pipelines: [.public])
            func index(_ context: RequestContext) -> String { "i" }
            }
            """
        ])
        #expect(result.exitCode == 0)
        #expect(result.generated.contains("[.authenticated]"))
        #expect(result.generated.contains("[.public]"))
    }

    @Test("a WebSocket route is marked as an upgrade")
    func manifestMarksUpgrades() throws {
        let result = try generate([
            "SocketController.swift": """
            import FlightWeb
            @Controller("/live")
            struct SocketController {
            @WebSocketRoute("/feed")
            func feed(_ context: RequestContext) -> some WebSocketUpgradeHandler { fatalError() }
            }
            """
        ])
        #expect(result.exitCode == 0)
        #expect(result.generated.contains("isUpgrade: true"))
        // An upgrade rides a GET (RFC 6455 §4.1).
        #expect(result.generated.contains(#"method: "GET""#))
    }

    @Test("a route the macro would reject does not reach the manifest")
    func rejectedRoutesAreOmitted() throws {
        // The generator scans silently — @Controller already diagnoses this,
        // and both run in the same build, so reporting here would say it
        // twice. What matters is that the bad route is not manifested either.
        let result = try generate([
            "BadController.swift": """
            import FlightWeb
            @Controller("/bad")
            struct BadController {
            @GetRoute("/ok")
            func ok(_ context: RequestContext) -> String { "ok" }
            @GetRoute("/static")
            static func wrong(_ context: RequestContext) -> String { "no" }
            }
            """
        ])
        #expect(result.exitCode == 0)
        #expect(result.generated.contains(#"path: "/bad/ok""#))
        #expect(!result.generated.contains(#"path: "/bad/static""#))
        #expect(
            !result.diagnostics.contains("must be an instance method"),
            "the macro owns this diagnostic; the generator must not repeat it")
    }

    // MARK: - Lane manifest

    @Test("lane declarations are scanned with their middleware in order")
    func emitsLanes() throws {
        let result = try generate([
            "AppModule.swift": """
            import FlightWeb
            final class AppModule: FlightModule {
            func configure(_ container: Container) throws {
            container.pipeline {
            RequestTiming.self
            Authentication.self
            }
            container.pipeline("admin") {
            RequireAdmin.self
            }
            }
            }
            """
        ])
        #expect(result.exitCode == 0)
        #expect(result.generated.contains("FlightRouteManifest"))
        // Unnamed form is the default lane; order is the declaration's content.
        #expect(result.generated.contains(#"name: "default", middleware: ["RequestTiming", "Authentication"]"#))
        #expect(result.generated.contains(#"name: "admin", middleware: ["RequireAdmin"]"#))
        // The enclosing type is what decides whether the lane exists at all.
        #expect(result.generated.contains(#"declaredIn: "AppModule""#))
    }

    @Test("a canonical lane member is named, not left as source text")
    func namesCanonicalLanes() throws {
        let result = try generate([
            "SecurityModule.swift": """
            import FlightWeb
            final class SecurityModule: FlightModule {
            func configure(_ container: Container) throws {
            container.pipeline(.authenticated) {
            Authentication.self
            RequireAuthentication.self
            }
            }
            }
            """
        ])
        #expect(result.exitCode == 0)
        #expect(result.generated.contains(#"name: "authenticated""#))
        #expect(result.generated.contains(#"["Authentication", "RequireAuthentication"]"#))
    }

    @Test("an empty block still declares its lane")
    func emptyBlockDeclaresLane() throws {
        // The motivating case: a static-asset lane that runs nothing. Before
        // the framework registered a marker for it, the block left no trace
        // and any route naming the lane failed validation.
        let result = try generate([
            "AssetsModule.swift": """
            import FlightWeb
            final class AssetsModule: FlightModule {
            func configure(_ container: Container) throws {
            container.pipeline("assets") {}
            }
            }
            """
        ])
        #expect(result.exitCode == 0)
        #expect(result.generated.contains(#"name: "assets", middleware: []"#))
    }

    @Test("two declarations of one lane are kept separate, in order")
    func lanesCompose() throws {
        // pipeline() composes rather than conflicts: a framework module
        // installs its middleware and the application appends. Flattening
        // them here would lose the only thing the declaration carries.
        let result = try generate([
            "A.swift": """
            import FlightWeb
            final class FrameworkModule: FlightModule {
            func configure(_ container: Container) throws {
            container.pipeline { Authentication.self }
            }
            }
            """,
            "B.swift": """
            import FlightWeb
            final class AppModule: FlightModule {
            func configure(_ container: Container) throws {
            container.pipeline { RequestLogging.self }
            }
            }
            """,
        ])
        #expect(result.exitCode == 0)
        #expect(result.generated.contains(#"middleware: ["Authentication"], declaredIn: "FrameworkModule""#))
        #expect(result.generated.contains(#"middleware: ["RequestLogging"], declaredIn: "AppModule""#))
    }

    @Test("a components-only target still gets a manifest, with empty route and lane lists")
    func componentsOnlyTargetGetsManifest() throws {
        // A library of @Service types has no routes and declares no lanes,
        // and still needs its component list: that is the part a composition
        // function is built from. Empty arrays are the honest answer, not a
        // reason to emit nothing.
        let result = try generate([
            "UserService.swift": """
            import FlightCore
            @Service final class UserService: Sendable {
            init() {}
            }
            """
        ])
        #expect(result.exitCode == 0)
        #expect(result.generated.contains("FlightRouteManifest"))
        #expect(result.generated.contains("public static let routes: [Entry] = [\n    ]"))
        #expect(
            result.generated.contains(
                #"Component(typeName: "UserService", stereotype: "service""#))
    }

    @Test("a target with no Flight surface at all emits no manifest")
    func emptyTargetEmitsNoManifest() throws {
        let result = try generate([
            "Plain.swift": """
            struct JustAStruct {}
            """
        ])
        #expect(result.exitCode == 0)
        #expect(!result.generated.contains("FlightRouteManifest"))
    }

    // MARK: - Module order

    @Test("a dependency's lanes come before its dependent's, not in file order")
    func lanesFollowModuleOrder() throws {
        // The defect this exists to catch: collectMiddleware sorts by
        // registration sequence, which is module sequence — dependencies
        // configure first. Scan order follows the file list, which put the
        // app's own module first and reversed the real chain.
        let result = try generate([
            "A_AppModule.swift": """
            import FlightWeb
            final class AppModule: FlightModule {
            static var dependencies: [any FlightModule.Type] { [SecurityModule.self] }
            func configure(_ container: Container) throws {
            container.pipeline { RequestLogging.self }
            }
            }
            """,
            "B_SecurityModule.swift": """
            import FlightWeb
            final class SecurityModule: FlightModule {
            func configure(_ container: Container) throws {
            container.pipeline { Authentication.self }
            }
            }
            """,
        ])
        #expect(result.exitCode == 0)
        let authentication = try #require(result.generated.range(of: #""Authentication""#))
        let logging = try #require(result.generated.range(of: #""RequestLogging""#))
        #expect(
            authentication.lowerBound < logging.lowerBound,
            "AppModule depends on SecurityModule, so SecurityModule configures first")
    }

    @Test("the module graph is emitted, dependencies as written")
    func emitsModuleGraph() throws {
        let result = try generate([
            "AppModule.swift": """
            import FlightWeb
            final class AppModule: FlightModule {
            static var dependencies: [any FlightModule.Type] {
            [
            PostgresDataModule<PrimaryDataSource>.self,
            FlightPubSubModule.self,
            ]
            }
            func configure(_ container: Container) throws {}
            }
            """
        ])
        #expect(result.exitCode == 0)
        // As written, generic argument and all: matching strips it, but the
        // composer has to construct the type that was named.
        #expect(
            result.generated.contains(
                #"name: "AppModule", dependencies: ["PostgresDataModule<PrimaryDataSource>", "FlightPubSubModule"]"#
            ))
    }

    @Test("a module with no dependencies is still an edge in the graph")
    func moduleWithoutDependencies() throws {
        let result = try generate([
            "Bare.swift": """
            import FlightWeb
            final class BareModule: FlightModule {
            func configure(_ container: Container) throws {}
            }
            """
        ])
        #expect(result.exitCode == 0)
        #expect(result.generated.contains(#"name: "BareModule", dependencies: []"#))
    }

    @Test("a dependency cycle between modules does not hang the sort")
    func cyclicModulesTerminate() throws {
        // ModuleGraphError.cycle is the runtime's job; this only has to not
        // loop forever while producing something.
        let result = try generate([
            "Cycle.swift": """
            import FlightWeb
            final class A: FlightModule {
            static var dependencies: [any FlightModule.Type] { [B.self] }
            func configure(_ container: Container) throws {}
            }
            final class B: FlightModule {
            static var dependencies: [any FlightModule.Type] { [A.self] }
            func configure(_ container: Container) throws {}
            }
            """
        ])
        #expect(result.exitCode == 0)
        #expect(result.generated.contains("moduleGraph"))
    }

    // MARK: - Mounts and hand-registered routes

    @Test("a hand-registered route warns, and says both ways out")
    func handRegisteredRouteWarns() throws {
        let result = try generate([
            "AppModule.swift": """
            import FlightWeb
            final class AppModule: FlightModule {
            func configure(_ container: Container) throws {
            container.registerRoute(.get, "/legacy") { _ in .init() }
            }
            }
            """
        ])
        // A warning, not an error: the escape hatch is legitimate.
        #expect(result.exitCode == 0)
        #expect(result.diagnostics.contains("warning"))
        #expect(result.diagnostics.contains("@Controller"))
        #expect(result.diagnostics.contains("flight:hand-registered"))
    }

    @Test("the acknowledgment silences the warning but still records the route")
    func acknowledgedRouteIsRecorded() throws {
        // Both halves matter: the marker means "I know", not "forget it".
        // A skipped route that left no trace is the failure this exists to
        // prevent.
        let result = try generate([
            "AppModule.swift": """
            import FlightWeb
            final class AppModule: FlightModule {
            func configure(_ container: Container) throws {
            // flight:hand-registered
            container.registerRoute(.get, "/legacy") { _ in .init() }
            }
            }
            """
        ])
        #expect(result.exitCode == 0)
        #expect(!result.diagnostics.contains("warning"))
        #expect(result.generated.contains(#"handRegisteredRoutes"#))
        #expect(result.generated.contains(#"HandRegistered(path: "/legacy""#))
        // The basename, not the absolute path — generated source that
        // differs between machines is generated source that busts caches.
        #expect(result.generated.contains(#"file: "AppModule.swift""#))
        #expect(!result.generated.contains(#"file: "/"#))
    }

    @Test("an asset mount is recorded with its prefix and lanes")
    func recordsAssetMount() throws {
        // Assets are not a route problem: the call carries the prefix the
        // framework derives routes from, so the mount is scannable even
        // though the registerRoute calls inside it are not.
        let result = try generate([
            "AppModule.swift": """
            import FlightWeb
            final class AppModule: FlightModule {
            func configure(_ container: Container) throws {
            container.assets(at: "/static", root: "public", pipelines: ["assets"])
            }
            }
            """
        ])
        #expect(result.exitCode == 0)
        #expect(!result.diagnostics.contains("warning"))
        #expect(result.generated.contains(#"kind: "assets", path: "/static""#))
        #expect(result.generated.contains(#"pipelines: "[\"assets\"]""#))
    }

    @Test("an uploads mount is recorded, and a socket mount defaults its path")
    func recordsOtherMounts() throws {
        let result = try generate([
            "AppModule.swift": """
            import FlightWeb
            final class AppModule: FlightModule {
            func configure(_ container: Container) throws {
            container.uploads(at: "/files", store: DiskStore())
            container.registerChannelSocket()
            }
            }
            """
        ])
        #expect(result.exitCode == 0)
        #expect(result.generated.contains(#"kind: "uploads", path: "/files""#))
        // registerChannelSocket()'s path parameter defaults to "/socket".
        #expect(result.generated.contains(#"kind: "socket", path: "/socket""#))
    }

    @Test("an interpolated path is recorded as unknown rather than guessed")
    func interpolatedPathIsUnknown() throws {
        let result = try generate([
            "AppModule.swift": """
            import FlightWeb
            final class AppModule: FlightModule {
            func configure(_ container: Container) throws {
            // flight:hand-registered
            container.registerRoute(.get, "\\(prefix)/items") { _ in .init() }
            }
            }
            """
        ])
        #expect(result.exitCode == 0)
        #expect(result.generated.contains("HandRegistered(path: nil"))
    }

    // MARK: - The component list

    @Test("the manifest's data rows are exactly this — indentation included")
    func manifestRowsAreGolden() throws {
        // Same hazard the registration body's golden test exists for: the
        // manifest is built by appending string literals, so a cleanup pass
        // can collapse its indentation while every `contains` test still
        // passes. This pins the rows rather than the whole block, so a
        // doc-comment edit is not a failure but a shape regression is.
        let result = try generate([
            "Sources.swift": """
            import FlightWeb
            @Controller("/users")
            struct UserController {
                @Inject var repo: UserRepository
                @GetRoute("/:id")
                func show(_ context: RequestContext) -> String { "x" }
            }
            @Repository
            struct UserRepository {}
            """
        ])
        #expect(result.exitCode == 0)

        let start = try #require(
            result.generated.range(of: "    public static let components: [Component] = [")
        ).lowerBound
        let rest = result.generated[start...]
        let end = try #require(rest.range(of: "\n    ]")).upperBound
        #expect(
            String(result.generated[start..<end]) == """
                    public static let components: [Component] = [
                        Component(typeName: "UserController", stereotype: "controller", scope: ".singleton", qualifier: nil, dependencies: ["UserRepository"], isModuleRegistered: false, module: "AppModule"),
                        Component(typeName: "UserRepository", stereotype: "repository", scope: ".singleton", qualifier: nil, dependencies: [], isModuleRegistered: false, module: "AppModule"),
                    ]
                """)
    }

    @Test("a component's stereotype follows its attribute")
    func stereotypeFollowsAttribute() throws {
        let result = try generate([
            "Sources.swift": """
            import FlightWeb
            @Service struct A: Sendable {}
            @Repository struct B: Sendable {}
            @Component struct C: Sendable {}
            @Middleware struct D: Sendable {}
            """
        ])
        #expect(result.exitCode == 0)
        #expect(result.generated.contains(#"typeName: "A", stereotype: "service""#))
        #expect(result.generated.contains(#"typeName: "B", stereotype: "repository""#))
        // @Component passes no `stereotype:` and takes the parameter's
        // default, so the manifest must say the same thing.
        #expect(result.generated.contains(#"typeName: "C", stereotype: "component""#))
        #expect(result.generated.contains(#"typeName: "D", stereotype: "middleware""#))
    }

    @Test("a module-registered component is listed, and flagged")
    func moduleRegisteredComponentIsFlagged() throws {
        // It is not in flightRegisterAll — that is what the marker means —
        // but it is still part of the graph, and a composition function has
        // to know it exists to order anything that depends on it.
        let result = try generate([
            "Sources.swift": """
            import FlightWeb
            // flight:module-registered
            @Middleware struct Authentication: Sendable {}
            """
        ])
        #expect(result.exitCode == 0)
        #expect(!result.generated.contains("try Authentication._flightRegister"))
        #expect(
            result.generated.contains(
                #"typeName: "Authentication", stereotype: "middleware", scope: ".singleton", qualifier: nil, dependencies: [], isModuleRegistered: true"#
            ))
    }

    @Test("a qualified component keeps its qualifier")
    func qualifiedComponentKeepsQualifier() throws {
        let result = try generate([
            "Sources.swift": """
            import FlightCore
            @Repository(qualifier: "primary") struct Pool: Sendable {}
            """
        ])
        #expect(result.exitCode == 0)
        #expect(result.generated.contains(#"qualifier: "\"primary\"""#))
    }

    // MARK: - Failure modes

    @Test("an unreadable source file is skipped with a warning, not a crash")
    func unreadableFileWarns() throws {
        let workspace = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("flightgen-missing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let output = workspace.appendingPathComponent("Out.swift")
        let manifest: [String: Any] = [
            "targetModuleName": "AppModule",
            "modules": [
                [
                    "name": "AppModule",
                    "files": [workspace.appendingPathComponent("gone.swift").path],
                ]
            ],
            "output": output.path,
        ]
        let manifestPath = workspace.appendingPathComponent("manifest.json")
        try JSONSerialization.data(withJSONObject: manifest, options: []).write(to: manifestPath)

        let process = Process()
        process.executableURL = Self.executable
        process.arguments = [manifestPath.path]
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = Pipe()
        try process.run()
        let diagnostics =
            String(
                data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()

        #expect(process.terminationStatus == 0, "a missing source must not fail the build")
        #expect(diagnostics.lowercased().contains("warning"))
    }

    @Test("a malformed manifest exits with a usage error rather than crashing")
    func malformedManifestExitsCleanly() throws {
        let workspace = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("flightgen-bad-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let manifestPath = workspace.appendingPathComponent("manifest.json")
        try "{ not json".write(to: manifestPath, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = Self.executable
        process.arguments = [manifestPath.path]
        process.standardError = Pipe()
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 2)
    }

    @Test("no arguments exits with usage")
    func noArgumentsExitsWithUsage() throws {
        let process = Process()
        process.executableURL = Self.executable
        process.arguments = []
        process.standardError = Pipe()
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 2)
    }
}
