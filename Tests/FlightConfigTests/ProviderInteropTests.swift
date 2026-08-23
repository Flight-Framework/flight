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
