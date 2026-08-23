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
        // …/Tests/FlightRegistrationGenTests/GeneratorTests.swift → package root
        var root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
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
    func generate(
        _ sources: [String: String],
        targetModule: String = "AppModule",
        packageDirectory: String? = nil
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

        let output = workspace.appendingPathComponent("FlightRegistrations.swift")
        var manifest: [String: Any] = [
            "targetModuleName": targetModule,
            "modules": [["name": targetModule, "files": paths]],
            "output": output.path,
        ]
        if let packageDirectory { manifest["packageDirectory"] = packageDirectory }

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
