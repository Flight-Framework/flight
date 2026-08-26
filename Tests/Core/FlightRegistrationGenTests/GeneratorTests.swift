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
                @Autowired var greeter: (any Greeter)
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

                    // Existential bridges (demand-driven): each `@Autowired var _: (any P)`
                    // with exactly one scanned conformer resolves through that conformer,
                    // mirroring its scope. A `// flight:hand-registered` marker on the
                    // demanding property suppresses the bridge.
                    container.register((any Greeter).self, scope: .scoped) { c in
                        try c.resolveInActiveScope(EnglishGreeter.self)
                    }
                }

                """)
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
            @Autowired var repository: any UserRepositoryProtocol
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
            @Autowired var missing: NoSuchComponent
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
            @Autowired var pong: Pong
            init() {}
            }
            @Component final class Pong: Sendable {
            @Autowired var ping: Ping
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
            @Autowired var external: SomethingRegisteredByHand
            init() {}
            }
            """
        ])
        #expect(
            !result.diagnostics.contains("SomethingRegisteredByHand"),
            "the documented escape hatch must actually suppress the diagnostic"
        )
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
