/// An in-memory source for use with Swift Testing (§7): hand it the exact
/// keys a test needs and nothing else.
///
/// ```swift
/// @Test
/// func dataSourceUsesConfiguredPoolSize() throws {
///     let config = Configuration(sources: [
///         TestConfigSource(["datasource.pool_size": "3"])
///     ])
///     #expect(try config.get("datasource.pool_size", as: Int.self) == 3)
/// }
/// ```
///
/// For integration-style tests that want real config *loading* — files,
/// layering, substitution — use `Configuration.load` with
/// `FlightEnvironment.test` and a `flight-test.yaml` instead; `test` is a
/// first-class environment case for exactly that purpose.
public struct TestConfigSource: ConfigSource {
    private var overrides: [String: String]

    public init(_ overrides: [String: String] = [:]) {
        self.overrides = overrides
    }

    public func rawValue(for key: String) -> String? {
        overrides[key]
    }
}
