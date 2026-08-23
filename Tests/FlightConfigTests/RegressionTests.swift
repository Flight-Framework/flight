import Foundation
import Testing
import Configuration
@testable import FlightConfig

/// Each test here pins a defect that shipped once. They are named for the
/// behavior, not the bug number, so they read as specifications.
@Suite("Secret handling")
struct SecretRedactionTests {

    @Test("a substituted value is redacted in a debug dump; a literal is not")
    func substitutedValuesAreRedacted() throws {
        let provider = try FlightYAMLProvider(
            string: """
            db:
              host: localhost
              password: "${AUDIT_DB_PASSWORD}"
            """,
            name: "flight.yaml",
            substitution: .resolve(["AUDIT_DB_PASSWORD": "hunter2"])
        )
        let dump = String(reflecting: provider)

        #expect(!dump.contains("hunter2"), "a substituted secret must never reach a debug dump")
        #expect(dump.contains("db.password=<REDACTED>"))
        // A literal in the file is already disclosed by the file itself.
        #expect(dump.contains("db.host=localhost"))
    }

    @Test("a ${VAR:-default} fallback is treated as substituted too")
    func fallbackValuesAreRedacted() throws {
        let provider = try FlightYAMLProvider(
            string: "token: ${AUDIT_TOKEN:-fallback-secret}",
            name: "flight.yaml",
            substitution: .resolve([:])
        )
        let dump = String(reflecting: provider)
        #expect(!dump.contains("fallback-secret"))
        #expect(dump.contains("token=<REDACTED>"))
    }

    @Test("the plain description never prints values at all")
    func descriptionPrintsNoValues() throws {
        let provider = try FlightYAMLProvider(
            string: "api:\n  key: literal-value",
            name: "flight.yaml",
            substitution: .none
        )
        #expect(!provider.description.contains("literal-value"))
    }
}

@Suite("Layer precedence")
struct PrecedenceTests {

    /// The override layer holds an array; the base layer holds a string under
    /// the same key. Answering from the base layer would resolve a production
    /// key from a development file, silently.
    @Test("a non-scalar in a higher layer never falls through to a lower one")
    func nonScalarDoesNotFallThrough() throws {
        let override = InMemoryProvider(
            name: "override", values: ["cluster.hosts": ConfigValue(.stringArray(["a", "b"]), isSecret: false)]
        )
        let base = InMemoryProvider(
            name: "base", values: ["cluster.hosts": "legacy-single"]
        )
        let config = Configuration(providers: [override, base])

        #expect(throws: ConfigError.self) {
            try config.resolveRawValue(for: "cluster.hosts")
        }
        // Crucially: it does NOT answer "legacy-single".
        #expect(config.rawValue(for: "cluster.hosts") == nil)
    }

    @Test("the error names the key, the layer, and the shape")
    func unrepresentableErrorIsActionable() throws {
        let provider = InMemoryProvider(
            name: "override", values: ["cluster.hosts": ConfigValue(.stringArray(["a"]), isSecret: false)]
        )
        let config = Configuration(providers: [provider])
        do {
            _ = try config.resolveRawValue(for: "cluster.hosts")
            Issue.record("expected a throw")
        } catch let error as ConfigError {
            let text = error.description
            #expect(text.contains("cluster.hosts"))
            #expect(text.contains("override"))
            #expect(text.contains("array of strings"))
        }
    }

    @Test("typed access surfaces the same failure rather than reporting absence")
    func typedAccessThrows() throws {
        let config = Configuration(providers: [
            InMemoryProvider(name: "override", values: ["a.b": ConfigValue(.intArray([1, 2]), isSecret: false)]),
            InMemoryProvider(name: "base", values: ["a.b": "7"]),
        ])
        #expect(throws: ConfigError.self) { try config.get("a.b", as: Int.self) }
        #expect(throws: ConfigError.self) { try config.getIfPresent("a.b", as: Int.self) }
    }

    @Test("scalar precedence still works normally")
    func scalarPrecedenceUnaffected() throws {
        let config = Configuration(providers: [
            InMemoryProvider(name: "override", values: ["server.port": 9090]),
            InMemoryProvider(name: "base", values: ["server.port": 8080]),
        ])
        #expect(try config.get("server.port", as: Int.self) == 9090)
    }

    @Test("absence still falls through to the next layer")
    func absenceFallsThrough() throws {
        let config = Configuration(providers: [
            InMemoryProvider(name: "override", values: [:]),
            InMemoryProvider(name: "base", values: ["server.port": 8080]),
        ])
        #expect(try config.get("server.port", as: Int.self) == 8080)
    }
}

@Suite("Parsing robustness")
struct ParsingRobustnessTests {

    @Test("a UTF-8 BOM does not become part of the first key")
    func bomIsStripped() throws {
        let document = try FlightYAMLDocument(
            string: "\u{FEFF}server:\n  port: 8080",
            name: "flight.yaml",
            substitution: .none
        )
        #expect(document.rawValue(for: "server.port") == "8080")
        #expect(document.keys == ["server.port"])
        #expect(!document.keys.contains { $0.hasPrefix("\u{FEFF}") })
    }

    @Test("a BOM-prefixed file resolves through the full configuration stack")
    func bomThroughProvider() throws {
        let provider = try FlightYAMLProvider(
            string: "\u{FEFF}server:\n  port: 8080", name: "flight.yaml", substitution: .none
        )
        let config = Configuration(providers: [provider])
        #expect(try config.get("server.port", as: Int.self) == 8080)
    }

    @Test("an unreadable file reports the condition, not an NSError dump")
    func unreadableFileMessageIsHumane() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("flight-audit-\(UUID().uuidString)")
            .appendingPathComponent("flight.yaml")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }

        do {
            _ = try FlightYAMLDocument(contentsOf: directory)
            Issue.record("expected a throw for a directory")
        } catch let error as ConfigLoadError {
            let text = error.description
            #expect(text.contains("it is a directory, not a file"))
            #expect(!text.contains("NSCocoaErrorDomain"))
            #expect(!text.contains("userInfo"))
        }
    }
}

@Suite("Key paths")
struct KeyPathTests {

    @Test("empty path components are not silently dropped")
    func emptyComponentsDoNotAlias() throws {
        let config = Configuration(providers: [
            InMemoryProvider(name: "base", values: ["a.b": "value"])
        ])
        #expect(config.rawValue(for: "a.b") == "value")
        // A typo must not resolve to the key you meant.
        #expect(config.rawValue(for: "a..b") == nil)
        #expect(config.rawValue(for: "a.b.") == nil)
    }
}

@Suite("Error ergonomics")
struct ErrorErgonomicsTests {

    @Test("localizedDescription carries the real message")
    func localizedDescriptionIsUseful() {
        let error = ConfigError.missingKey(key: "server.port", environment: .prod)
        #expect(error.localizedDescription.contains("server.port"))
        #expect(!error.localizedDescription.contains("error 0"))

        let load = ConfigLoadError.missingBaseFile(expectedPath: "/etc/flight.yaml")
        #expect(load.localizedDescription.contains("/etc/flight.yaml"))
    }

    @Test("ConfigError is Equatable, so adopters can assert on it directly")
    func errorsAreEquatable() {
        #expect(
            ConfigError.decodingFailed(key: "a", rawValue: "x", targetType: "Int")
                == ConfigError.decodingFailed(key: "a", rawValue: "x", targetType: "Int")
        )
        #expect(
            ConfigError.missingKey(key: "a", environment: .prod)
                != ConfigError.missingKey(key: "a", environment: .dev)
        )
    }
}
