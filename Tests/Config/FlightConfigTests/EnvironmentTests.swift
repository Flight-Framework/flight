import Testing
@testable import FlightConfig

@Suite("FlightEnvironment")
struct FlightEnvironmentTests {

    @Test("unset FLIGHT_ENV defaults to dev — a valid local state, never a throw")
    func unsetDefaultsToDev() {
        #expect(FlightEnvironment.current(from: [:]) == .dev)
    }

    @Test("the standard environments resolve from their raw values")
    func standardEnvironments() {
        for env in FlightEnvironment.standard {
            #expect(FlightEnvironment.current(from: ["FLIGHT_ENV": env.rawValue]) == env)
        }
    }

    @Test("an unset or empty FLIGHT_ENV resolves to dev")
    func absentDefaultsToDev() {
        #expect(FlightEnvironment.current(from: [:]) == .dev)
        #expect(FlightEnvironment.current(from: ["FLIGHT_ENV": ""]) == .dev)
    }

    @Test("a non-standard value resolves to itself, not silently to dev")
    func nonStandardResolvesToItself() {
        // Collapsing an unknown name to `dev` would load development
        // configuration under a production-shaped name, silently. Resolving
        // to itself means the missing flight-qa.yaml is visible instead.
        #expect(FlightEnvironment.current(from: ["FLIGHT_ENV": "qa"]) == FlightEnvironment("qa"))
        #expect(FlightEnvironment.current(from: ["FLIGHT_ENV": "production"]).rawValue == "production")
        #expect(FlightEnvironment.current(from: ["FLIGHT_ENV": "production"]) != .prod)
    }

    @Test("an app can define its own environments")
    func extensibility() {
        let qa = FlightEnvironment("qa")
        #expect(qa.rawValue == "qa")
        #expect(FlightEnvironment.current(from: ["FLIGHT_ENV": "qa"]) == qa)
        #expect(!FlightEnvironment.standard.contains(qa))
    }

    @Test("current() reads the real process environment without throwing")
    func currentReadsProcess() {
        // Can't assert a specific value without mutating global state; the
        // contract is "always resolves, never throws".
        _ = FlightEnvironment.current()
    }
}

@Suite("EnvironmentVariablesSource")
struct EnvironmentVariablesSourceTests {

    @Test("the fixed transform: uppercase, dots to underscores, FLIGHT_ prefix")
    func transform() {
        #expect(EnvironmentVariablesSource.variableName(for: "datasource.url") == "FLIGHT_DATASOURCE_URL")
        #expect(EnvironmentVariablesSource.variableName(for: "datasource.pool_size") == "FLIGHT_DATASOURCE_POOL_SIZE")
        #expect(EnvironmentVariablesSource.variableName(for: "server.port") == "FLIGHT_SERVER_PORT")
        #expect(EnvironmentVariablesSource.variableName(for: "key") == "FLIGHT_KEY")
    }

    @Test("keys resolve through the transform")
    func resolution() {
        let source = EnvironmentVariablesSource(environment: [
            "FLIGHT_DATASOURCE_URL": "postgres://injected",
            "FLIGHT_SERVER_PORT": "9999",
            "UNPREFIXED": "ignored",
        ])
        #expect(source.rawValue(for: "datasource.url") == "postgres://injected")
        #expect(source.rawValue(for: "server.port") == "9999")
        #expect(source.rawValue(for: "unprefixed") == nil, "only FLIGHT_-prefixed names participate")
        #expect(source.rawValue(for: "missing.key") == nil)
    }

    @Test("set-but-empty is a present value — it overrides lower layers")
    func emptyValueIsPresent() throws {
        let config = Configuration(sources: [
            EnvironmentVariablesSource(environment: ["FLIGHT_FEATURE_FLAG": ""]),
            TestConfigSource(["feature.flag": "from-file"]),
        ])
        #expect(try config.get("feature.flag", as: String.self) == "")
    }

    @Test("defaults to a snapshot of the real process environment")
    func defaultSnapshot() {
        _ = EnvironmentVariablesSource()  // constructible without arguments
    }
}
