import Foundation
import Configuration
import Testing
@testable import FlightConfig

/// The seam between Flight's string-native resolution and
/// swift-configuration's type-directed provider lookup.
///
/// A provider is asked for a specific `ConfigType`, and one holding a typed
/// value — a JSON/TOML integer, an `InMemoryProvider` `Int` — refuses a
/// `.string` request outright rather than stringifying it. Flight decodes from
/// raw strings, so these tests pin the coercion that keeps typed providers
/// usable: without it every non-string value in a third-party provider reads
/// as *absent*, which silently resolves the key from a lower layer instead.
@Suite("Typed providers through the Configuration facade")
struct ProviderInteropTests {

    @Test("typed scalars in a provider decode through Flight's accessors")
    func typedScalarsDecode() throws {
        let configuration = Configuration(providers: [
            InMemoryProvider(values: [
                "datasource.url": "postgres://localhost:5432/flight",
                "datasource.pool_size": 50,
                "datasource.enabled": true,
                "datasource.ratio": 1.5,
            ])
        ])

        #expect(try configuration.get("datasource.url", as: String.self) == "postgres://localhost:5432/flight")
        #expect(try configuration.get("datasource.pool_size", as: Int.self) == 50)
        #expect(try configuration.get("datasource.enabled", as: Bool.self) == true)
        #expect(try configuration.get("datasource.ratio", as: Double.self) == 1.5)
    }

    @Test("a typed value is present, not absent — no fall-through to a lower layer")
    func typedValueDoesNotFallThrough() throws {
        // The regression this whole coercion exists to prevent: an override
        // layer holding a typed 50 must win over the base layer's 5, not read
        // as absent and let the base value through.
        let configuration = Configuration(providers: [
            InMemoryProvider(name: "override", values: ["datasource.pool_size": 50]),
            InMemoryProvider(name: "base", values: ["datasource.pool_size": "5"]),
        ])

        #expect(try configuration.get("datasource.pool_size", as: Int.self) == 50)
    }

    @Test("a typed value reads as a string when that is what was asked for")
    func typedValueRendersAsString() throws {
        let configuration = Configuration(providers: [
            InMemoryProvider(values: ["server.port": 8080])
        ])

        #expect(configuration.rawValue(for: "server.port") == "8080")
        #expect(try configuration.get("server.port", as: String.self) == "8080")
    }

    @Test("absent keys stay absent across a typed stack")
    func absentAcrossTypedStack() throws {
        let configuration = Configuration(providers: [
            InMemoryProvider(values: ["server.port": 8080])
        ])

        #expect(configuration.rawValue(for: "server.host") == nil)
        #expect(try configuration.getIfPresent("server.host", as: String.self) == nil)
        #expect(throws: ConfigError.self) {
            try configuration.get("server.host", as: String.self)
        }
    }

    @Test("Flight YAML serves the swift-configuration reader API directly")
    func yamlServesReaderAPI() throws {
        let provider = try FlightYAMLProvider(
            string: """
            server:
              port: 8080
              host: localhost
              tls: true
            """,
            name: "flight.yaml",
            substitution: .none
        )
        let reader = ConfigReader(provider: provider)

        // Values are strings in the document; the snapshot converts on demand,
        // so a library reading through ConfigReader sees real types.
        #expect(reader.int(forKey: "server.port") == 8080)
        #expect(reader.string(forKey: "server.host") == "localhost")
        #expect(reader.bool(forKey: "server.tls") == true)
    }

    @Test("flattened sequences reassemble as arrays for the reader API")
    func sequencesReassemble() throws {
        let provider = try FlightYAMLProvider(
            string: """
            cluster:
              hosts:
                - alpha
                - beta
                - gamma
              ports:
                - 9001
                - 9002
            """,
            name: "flight.yaml",
            substitution: .none
        )
        let reader = ConfigReader(provider: provider)

        #expect(reader.stringArray(forKey: "cluster.hosts") == ["alpha", "beta", "gamma"])
        #expect(reader.intArray(forKey: "cluster.ports") == [9001, 9002])

        // Index addressing still works — it is how the keys are actually stored.
        let configuration = Configuration(providers: [provider])
        #expect(try configuration.get("cluster.hosts.1", as: String.self) == "beta")
    }

    @Test("the reader escape hatch exposes the same layered stack")
    func readerEscapeHatch() throws {
        // The stack Configuration.load builds: a bridged env-var-style source
        // over a YAML layer. Both of Flight's providers convert on demand, so
        // the reader sees real types all the way down.
        let configuration = Configuration(providers: [
            ConfigSourceProvider(source: TestConfigSource(["server.port": "9090"])),
            try FlightYAMLProvider(
                string: """
                server:
                  port: 8080
                  host: localhost
                """,
                name: "flight.yaml",
                substitution: .none
            ),
        ])

        // Precedence and key-by-key merge survive the handoff to a library
        // that speaks ConfigReader rather than Flight's accessors.
        #expect(configuration.reader.int(forKey: "server.port") == 9090)
        #expect(configuration.reader.string(forKey: "server.host") == "localhost")
    }

    @Test("a raw InMemoryProvider does not convert — Flight's providers do")
    func inMemoryProviderDoesNotConvert() throws {
        // Worth pinning because it is the trap a user hits when they reach
        // past Flight's providers: swift-configuration's own InMemoryProvider
        // stores whatever type it was given and refuses conversions, so a
        // string "9090" is invisible to an `int` request. Flight's accessors
        // are unaffected — they resolve raw strings and decode themselves —
        // which is why the facade never delegates to the reader.
        let stringly = ConfigReader(provider: InMemoryProvider(values: ["server.port": "9090"]))
        #expect(stringly.int(forKey: "server.port") == nil)

        let configuration = Configuration(providers: [
            InMemoryProvider(values: ["server.port": "9090"])
        ])
        #expect(try configuration.get("server.port", as: Int.self) == 9090)
    }

    @Test("a ConfigSource still bridges into the provider stack")
    func sourceBridge() throws {
        // The pre-migration spelling, unchanged: sources compose with
        // providers in one stack, highest precedence first.
        let configuration = Configuration(providers: [
            ConfigSourceProvider(source: TestConfigSource(["server.port": "9090"])),
            InMemoryProvider(values: ["server.port": 8080, "server.host": "localhost"]),
        ])

        #expect(try configuration.get("server.port", as: Int.self) == 9090)
        #expect(try configuration.get("server.host", as: String.self) == "localhost")
    }

    @Test("a bridged source answers typed requests from the reader API")
    func bridgedSourceIsTyped() throws {
        let reader = ConfigReader(
            provider: ConfigSourceProvider(source: TestConfigSource(["server.port": "8080"]))
        )
        #expect(reader.int(forKey: "server.port") == 8080)
    }
}

/// A provider that fails rather than answering — a secrets store that is
/// down, a permission denied, a socket timeout.
///
/// `additionalProviders` explicitly invites remote providers (Vault, AWS
/// Secrets Manager), so this is not a hypothetical shape.
struct FailingProvider: ConfigProvider {
    struct Unreachable: Error, CustomStringConvertible {
        var description: String { "vault: connection refused" }
    }
    let providerName = "vault"

    func value(forKey key: AbsoluteConfigKey, type: ConfigType) throws -> LookupResult {
        throw Unreachable()
    }

    func fetchValue(forKey key: AbsoluteConfigKey, type: ConfigType) async throws -> LookupResult {
        throw Unreachable()
    }

    func snapshot() -> any ConfigSnapshot { Snapshot() }

    func watchValue<Return: ~Copyable>(
        forKey key: AbsoluteConfigKey,
        type: ConfigType,
        updatesHandler: nonisolated(nonsending) (
            _ updates: ConfigUpdatesAsyncSequence<Result<LookupResult, any Error>, Never>
        ) async throws -> Return
    ) async throws -> Return {
        try await watchValueFromValue(forKey: key, type: type, updatesHandler: updatesHandler)
    }

    func watchSnapshot<Return: ~Copyable>(
        updatesHandler: nonisolated(nonsending) (
            _ updates: ConfigUpdatesAsyncSequence<any ConfigSnapshot, Never>
        ) async throws -> Return
    ) async throws -> Return {
        try await watchSnapshotFromSnapshot(updatesHandler: updatesHandler)
    }

    struct Snapshot: ConfigSnapshot {
        let providerName = "vault"
        func value(forKey key: AbsoluteConfigKey, type: ConfigType) throws -> LookupResult {
            throw Unreachable()
        }
    }
}

/// The one failure mode layered configuration must never have.
@Suite("A provider that fails is not a provider that is empty")
struct ProviderFailureTests {

    @Test("a failing high-precedence provider does not answer from a lower layer")
    func failureDoesNotFallThrough() throws {
        // Every provider error was swallowed by `try?` and read as "the key
        // is absent here", so a transient failure in the secrets provider
        // silently answered from the dev YAML underneath it — resolving a
        // production key from a development layer, which the code's own
        // comment names as the thing that must never happen.
        let configuration = Configuration(providers: [
            FailingProvider(),
            InMemoryProvider(name: "dev", values: ["datasource.password": "dev-password"]),
        ])

        #expect(throws: ConfigError.self) {
            try configuration.get("datasource.password", as: String.self)
        }
        #expect(throws: ConfigError.self) {
            try configuration.getIfPresent("datasource.password", as: String.self)
        }
    }

    @Test("the failure names the provider and carries the underlying reason")
    func failureIsDiagnosable() throws {
        let configuration = Configuration(providers: [FailingProvider()])
        do {
            _ = try configuration.get("datasource.password", as: String.self)
            Issue.record("expected a failure")
        } catch let error as ConfigError {
            #expect(error.description.contains("vault"))
            #expect(error.description.contains("connection refused"))
        }
    }

    @Test("a lower-precedence provider failing still stops the walk")
    func failureBelowAResolvedLayerIsNotReached() throws {
        // A provider above it answered, so the failing one is never asked —
        // resolution is first-hit and must stay that way.
        let configuration = Configuration(providers: [
            InMemoryProvider(name: "override", values: ["datasource.password": "real"]),
            FailingProvider(),
        ])
        #expect(try configuration.get("datasource.password", as: String.self) == "real")
    }
}

/// A reporter that just records, so a test can assert what was observed.
private final class RecordingReporter: AccessReporter, @unchecked Sendable {
    private let lock = NSLock()
    private var events: [AccessEvent] = []

    func report(_ event: AccessEvent) {
        lock.lock()
        defer { lock.unlock() }
        events.append(event)
    }

    var recorded: [AccessEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

/// `accessReporter` is documented as receiving "an event per resolved key",
/// and it only ever fired for reads through `Configuration.reader` — the
/// escape hatch — while `get`/`getIfPresent`, the accessors the library
/// tells you to prefer, walked the providers directly and reported nothing.
@Suite("Access reporting from Flight's own accessors")
struct AccessReportingTests {

    @Test("a resolved key is reported, naming every layer consulted")
    func resolvedKeyIsReported() throws {
        let reporter = RecordingReporter()
        let configuration = Configuration(
            providers: [
                InMemoryProvider(name: "override", values: [:]),
                InMemoryProvider(name: "base", values: ["server.port": 8080]),
            ],
            accessReporter: reporter)

        #expect(try configuration.get("server.port", as: Int.self) == 8080)

        let events = reporter.recorded
        #expect(events.count == 1)
        let event = try #require(events.first)
        #expect(event.metadata.key.components == ["server", "port"])
        #expect(
            event.providerResults.map(\.providerName)
                == ["InMemoryProvider[override]", "InMemoryProvider[base]"])
        #expect(event.metadata.sourceLocation.fileID.hasSuffix("ProviderInteropTests.swift"))
    }

    @Test("an absent key is reported too, as a successful nil")
    func absentKeyIsReported() throws {
        let reporter = RecordingReporter()
        let configuration = Configuration(
            providers: [InMemoryProvider(values: [:])], accessReporter: reporter)

        #expect(try configuration.getIfPresent("server.port", as: Int.self) == nil)
        let event = try #require(reporter.recorded.first)
        switch event.result {
        case .success(let value): #expect(value == nil)
        case .failure(let error): Issue.record("expected an absent result, got \(error)")
        }
    }

    @Test("a substituted value is reported as a secret, so a reporter can redact")
    func substitutedValuesAreSecret() throws {
        // Every ConfigValue the YAML snapshot built was flagged
        // `isSecret: false`, including the ones resolved from ${...} — so
        // config.md's promise that substituted values "render as <REDACTED>
        // in any diagnostic dump" held for the provider's own
        // debugDescription and nowhere else. A read through a reporter
        // logged the resolved secret verbatim.
        setenv("FLIGHT_TEST_DB_PASSWORD", "hunter2", 1)
        defer { unsetenv("FLIGHT_TEST_DB_PASSWORD") }

        let provider = try FlightYAMLProvider(
            string: """
                datasource:
                  url: postgres://localhost/app
                  password: ${FLIGHT_TEST_DB_PASSWORD}
                """,
            name: "flight.yaml",
            substitution: .processEnvironment)
        let reporter = RecordingReporter()
        let configuration = Configuration(providers: [provider], accessReporter: reporter)

        #expect(try configuration.get("datasource.password", as: String.self) == "hunter2")
        #expect(try configuration.get("datasource.url", as: String.self)
            == "postgres://localhost/app")

        let secrecy = reporter.recorded.map { event -> Bool? in
            guard case .success(let value) = event.result else { return nil }
            return value?.isSecret
        }
        #expect(secrecy == [true, false], "substituted values must carry the secret flag")
    }
}
