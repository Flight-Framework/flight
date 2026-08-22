import Testing
@testable import FlightConfig

@Suite("Configuration — layering and typed access")
struct ConfigurationTests {

    // MARK: Precedence (§3)

    @Test("first source holding a key wins")
    func precedenceOrder() throws {
        let config = Configuration(sources: [
            TestConfigSource(["shared.key": "from-high"]),
            TestConfigSource(["shared.key": "from-low"]),
        ])
        #expect(try config.get("shared.key", as: String.self) == "from-high")
    }

    @Test("merge is key-by-key, not source-by-source")
    func keyByKeyMerge() throws {
        // The §3 example: the env layer overrides only pool_size; url still
        // resolves from base.
        let environmentLayer = TestConfigSource(["datasource.pool_size": "50"])
        let base = TestConfigSource([
            "datasource.url": "postgres://localhost:5432/flight_dev",
            "datasource.pool_size": "5",
            "server.port": "8080",
        ])
        let config = Configuration(sources: [environmentLayer, base])

        #expect(try config.get("datasource.pool_size", as: Int.self) == 50)
        #expect(try config.get("datasource.url", as: String.self) == "postgres://localhost:5432/flight_dev")
        #expect(try config.get("server.port", as: Int.self) == 8080)
    }

    @Test("a source returning nil defers to the next source")
    func nilFallsThrough() throws {
        struct EmptySource: ConfigSource {
            func rawValue(for key: String) -> String? { nil }
        }
        let config = Configuration(sources: [EmptySource(), TestConfigSource(["k": "v"])])
        #expect(try config.get("k", as: String.self) == "v")
    }

    // MARK: get(_:as:) failures (§2)

    @Test("missing key throws ConfigError.missingKey with the key")
    func missingKey() {
        let config = Configuration(values: [:])
        #expect {
            try config.get("datasource.url", as: String.self)
        } throws: { error in
            guard case ConfigError.missingKey(let key, let environment) = error else { return false }
            return key == "datasource.url" && environment == nil
        }
    }

    @Test("missingKey carries the active environment when the configuration has one")
    func missingKeyNamesEnvironment() {
        let config = Configuration(sources: [TestConfigSource()], environment: .prod)
        #expect {
            try config.get("datasource.url", as: String.self)
        } throws: { error in
            guard case ConfigError.missingKey(_, let environment) = error else { return false }
            return environment == .prod
        }
    }

    @Test("missingKey message names the satisfying env var")
    func missingKeyMessage() {
        let config = Configuration(sources: [TestConfigSource()], environment: .prod)
        do {
            _ = try config.get("datasource.url", as: String.self)
            Issue.record("expected missingKey")
        } catch {
            let message = "\(error)"
            #expect(message.contains("datasource.url"))
            #expect(message.contains("prod"))
            #expect(message.contains("FLIGHT_DATASOURCE_URL"))
        }
    }

    @Test("present but undecodable throws ConfigError.decodingFailed")
    func decodingFailed() {
        let config = Configuration(values: ["server.port": "eight thousand"])
        #expect {
            try config.get("server.port", as: Int.self)
        } throws: { error in
            guard case ConfigError.decodingFailed(let key, let raw, let type) = error else { return false }
            return key == "server.port" && raw == "eight thousand" && type == Int.self
        }
    }

    @Test("the design doc's §7 example holds verbatim")
    func designDocExample() throws {
        let config = Configuration(sources: [
            TestConfigSource(["datasource.pool_size": "3"])
        ])
        #expect(try config.get("datasource.pool_size", as: Int.self) == 3)
    }

    // MARK: get(_:default:)

    @Test("default applies when the key is absent everywhere")
    func defaultOnMissing() {
        let config = Configuration(values: [:])
        #expect(config.get("datasource.pool_size", default: 10) == 10)
    }

    @Test("a present key beats the default")
    func presentBeatsDefault() {
        let config = Configuration(values: ["datasource.pool_size": "3"])
        #expect(config.get("datasource.pool_size", default: 10) == 3)
    }

    // MARK: getIfPresent

    @Test("getIfPresent: nil when absent, value when present, throws when malformed")
    func getIfPresent() throws {
        let config = Configuration(values: ["tls.port": "8443", "tls.bad": "nope"])
        #expect(try config.getIfPresent("tls.cert_path", as: String.self) == nil)
        #expect(try config.getIfPresent("tls.port", as: Int.self) == 8443)
        #expect(throws: ConfigError.self) {
            try config.getIfPresent("tls.bad", as: Int.self)
        }
    }

    // MARK: Raw access

    @Test("rawValue exposes the winning raw string without decoding")
    func rawAccess() {
        let config = Configuration(sources: [
            TestConfigSource(["a": "1"]),
            TestConfigSource(["a": "2", "b": "x"]),
        ])
        #expect(config.rawValue(for: "a") == "1")
        #expect(config.rawValue(for: "b") == "x")
        #expect(config.rawValue(for: "c") == nil)
    }

    @Test("values: convenience behaves as a single in-memory source")
    func valuesConvenience() throws {
        let config = Configuration(values: ["greeting.name": "flight"])
        #expect(try config.get("greeting.name", as: String.self) == "flight")
        #expect(config.environment == nil)
    }

    @Test("empty configuration resolves nothing and defaults apply")
    func emptyConfiguration() {
        let config = Configuration()
        #expect(config.rawValue(for: "anything") == nil)
        #expect(config.get("anything", default: "fallback") == "fallback")
    }
}
