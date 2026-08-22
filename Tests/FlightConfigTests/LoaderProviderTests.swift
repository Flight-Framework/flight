import Configuration
import Foundation
import Testing
@testable import FlightConfig

/// `Configuration.load`'s provider-era parameters: the extension point §8
/// deferred, plus secret marking. The base layering these sit on top of is
/// covered by `LoaderTests`.
@Suite("Configuration.load — providers, secrets, reporting")
struct LoaderProviderTests {

    private func withConfigDirectory<T>(
        files: [String: String],
        _ body: (URL) throws -> T
    ) throws -> T {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("flight-config-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for (name, contents) in files {
            try contents.write(
                to: directory.appendingPathComponent(name),
                atomically: true, encoding: .utf8
            )
        }
        return try body(directory)
    }

    private let baseYAML = """
    datasource:
      url: "postgres://localhost:5432/flight_dev"
      pool_size: 5
    """

    @Test("additionalProviders sit above the env-var layer and win")
    func additionalProvidersWin() throws {
        try withConfigDirectory(files: ["flight.yaml": baseYAML]) { directory in
            let config = try Configuration.load(
                from: directory,
                processEnvironment: ["FLIGHT_DATASOURCE_POOL_SIZE": "50"],
                additionalProviders: [InMemoryProvider(values: ["datasource.pool_size": 99])]
            )

            // Above env vars — which are themselves above both files.
            #expect(try config.get("datasource.pool_size", as: Int.self) == 99)
            // Keys the extra provider says nothing about still fall through.
            #expect(
                try config.get("datasource.url", as: String.self)
                    == "postgres://localhost:5432/flight_dev"
            )
        }
    }

    @Test("the env-var layer still encodes keys the §3 way")
    func envLayerEncoding() throws {
        try withConfigDirectory(files: ["flight.yaml": baseYAML]) { directory in
            let config = try Configuration.load(
                from: directory,
                processEnvironment: ["FLIGHT_DATASOURCE_POOL_SIZE": "50"]
            )
            // prefixKeys(with: "flight") must reproduce
            // EnvironmentVariablesSource.variableName(for:) exactly.
            #expect(try config.get("datasource.pool_size", as: Int.self) == 50)
            #expect(
                EnvironmentVariablesSource.variableName(for: "datasource.pool_size")
                    == "FLIGHT_DATASOURCE_POOL_SIZE"
            )
        }
    }

    @Test("secret-marked values resolve normally but redact in descriptions")
    func secretsRedact() throws {
        try withConfigDirectory(files: ["flight.yaml": baseYAML]) { directory in
            let config = try Configuration.load(
                from: directory,
                processEnvironment: ["FLIGHT_DATASOURCE_PASSWORD": "hunter2"],
                secrets: .specific(["FLIGHT_DATASOURCE_PASSWORD"])
            )

            // The value is still readable by the app that needs it …
            #expect(try config.get("datasource.password", as: String.self) == "hunter2")

            // … the summary never prints values at all …
            #expect(!config.description.contains("hunter2"))

            // … and the debug dump names the variable but redacts its value.
            let dump = config.debugDescription
            #expect(dump.contains("FLIGHT_DATASOURCE_PASSWORD=<REDACTED>"))
            #expect(!dump.contains("hunter2"))
        }
    }

    @Test("an access reporter observes resolved keys")
    func accessReporting() throws {
        final class Recorder: AccessReporter, @unchecked Sendable {
            private let lock = NSLock()
            private var _keys: [String] = []
            var keys: [String] {
                lock.lock(); defer { lock.unlock() }
                return _keys
            }
            func report(_ event: AccessEvent) {
                lock.lock(); defer { lock.unlock() }
                _keys.append(event.metadata.key.description)
            }
        }

        try withConfigDirectory(files: ["flight.yaml": baseYAML]) { directory in
            let recorder = Recorder()
            let config = try Configuration.load(
                from: directory,
                processEnvironment: [:],
                accessReporter: recorder
            )

            // Reporting is a reader-side facility: Flight's own accessors go
            // straight to the providers, so events appear for reads made
            // through the interop surface.
            _ = config.reader.int(forKey: "datasource.pool_size")
            #expect(recorder.keys.contains { $0.contains("pool_size") })
        }
    }
}
