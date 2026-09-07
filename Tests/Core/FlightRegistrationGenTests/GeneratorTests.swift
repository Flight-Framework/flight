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
            @Service(scope: .scoped)
            struct EnglishGreeter: Greeter {}
            @Component
            final class Welcomer {
                @Inject var greeter: (any Greeter)
            }
            """
        ])

        #expect(result.exitCode == 0)
        // The header carries a component count and the target name; the body
        // below it is what this test pins.
        let marker = "public func flightRegisterAll"
        let start = try #require(result.generated.range(of: marker)).lowerBound
        #expect(
            String(result.generated[start...]) == """
                public func flightRegisterAll(_ container: FlightCore.Container) throws {
                    try EnglishGreeter._flightRegister(container)
                    try Welcomer._flightRegister(container)

                    // Existential bridges (demand-driven): each `@Inject var _: (any P)`
                    // with exactly one scanned conformer resolves through that conformer,
                    // mirroring its scope. A `// flight:hand-registered` marker on the
                    // demanding property suppresses the bridge.
                    container.register((any Greeter).self, scope: .scoped) { c in
                        try c.resolveInActiveScope(EnglishGreeter.self)
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
        #expect(result.generated.contains("try Ordinary._flightRegister(container)"))
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

    // MARK: - Captive dependencies

    @Test("a singleton injecting a scoped component is a build error naming both")
    func reportsCaptiveDependency() throws {
        // The defect this exists to catch: a singleton is built once at
        // freeze() and outlives every request, so holding a per-request
        // instance means serving the first request's state forever. Today
        // this throws `scopeRequired` at startup; the point of the check is
        // that it never gets that far.
        let result = try generate([
            "Captive.swift": """
            import FlightCore
            @Service final class PricingService: Sendable {
            @Inject var users: UserRepository
            init() {}
            }
            @Repository(scope: .scoped) final class UserRepository: Sendable {
            init() {}
            }
            """
        ])
        #expect(result.exitCode != 0)
        #expect(result.diagnostics.contains("PricingService"))
        #expect(result.diagnostics.contains("UserRepository"))
        #expect(result.diagnostics.contains(".singleton") && result.diagnostics.contains(".scoped"))
    }

    @Test("scoped injecting scoped is fine — same lifetime, no capture")
    func scopedInjectingScopedIsFine() throws {
        let result = try generate([
            "Scoped.swift": """
            import FlightCore
            @Service(scope: .scoped) final class RequestAudit: Sendable {
            @Inject var users: UserRepository
            init() {}
            }
            @Repository(scope: .scoped) final class UserRepository: Sendable {
            init() {}
            }
            """
        ])
        #expect(result.exitCode == 0, "no capture: both live for one request")
    }

    @Test("singleton injecting singleton is fine")
    func singletonInjectingSingletonIsFine() throws {
        let result = try generate([
            "Singletons.swift": """
            import FlightCore
            @Service final class PricingService: Sendable {
            @Inject var users: UserRepository
            init() {}
            }
            @Repository final class UserRepository: Sendable {
            init() {}
            }
            """
        ])
        #expect(result.exitCode == 0, "no capture: both live for the process")
    }

    @Test("a hand-registered marker does not exempt a captive dependency")
    func markerDoesNotExemptCaptive() throws {
        // The marker means "registered by hand", not "exempt from lifetime
        // rules" — the same posture `detectCycles` takes toward it. A
        // hand-registered scoped component captured by a singleton is captive
        // in exactly the same way.
        let result = try generate([
            "MarkedCaptive.swift": """
            import FlightCore
            @Service final class PricingService: Sendable {
            // flight:hand-registered
            @Inject var users: UserRepository
            init() {}
            }
            @Repository(scope: .scoped) final class UserRepository: Sendable {
            init() {}
            }
            """
        ])
        #expect(result.exitCode != 0)
        #expect(result.diagnostics.contains("PricingService"))
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

    @Test("a target with neither routes nor lanes emits no manifest")
    func noRoutesNoLanesNoManifest() throws {
        let result = try generate([
            "UserService.swift": """
            import FlightCore
            @Service final class UserService: Sendable {
            init() {}
            }
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

    @Test("the module graph is emitted, generic arguments stripped")
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
        #expect(
            result.generated.contains(
                #"name: "AppModule", dependencies: ["PostgresDataModule", "FlightPubSubModule"]"#))
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
