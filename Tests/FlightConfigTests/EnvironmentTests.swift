import Testing
@testable import FlightConfig

@Suite("FlightEnvironment (§4)")
struct FlightEnvironmentTests {

    @Test("unset FLIGHT_ENV defaults to dev — a valid local state, never a throw")
    func unsetDefaultsToDev() {
        #expect(FlightEnvironment.current(from: [:]) == .dev)
    }

    @Test("all four environments resolve from their raw values")
    func allCases() {
        for env in FlightEnvironment.allCases {
            #expect(FlightEnvironment.current(from: ["FLIGHT_ENV": env.rawValue]) == env)
        }
    }

    @Test("unrecognized values resolve to dev, per the design contract")
    func unrecognizedDefaultsToDev() {
        #expect(FlightEnvironment.current(from: ["FLIGHT_ENV": "production"]) == .dev)
        #expect(FlightEnvironment.current(from: ["FLIGHT_ENV": "PROD"]) == .dev)
        #expect(FlightEnvironment.current(from: ["FLIGHT_ENV": ""]) == .dev)
    }

    @Test("current() reads the real process environment without throwing")
    func currentReadsProcess() {
        // Can't assert a specific value without mutating global state; the
        // contract is "always resolves, never throws".
        _ = FlightEnvironment.current()
    }
}

@Suite("EnvironmentVariablesSource (§3 layer 1)")
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
