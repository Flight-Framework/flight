import Foundation

/// The active deployment environment, resolved from `FLIGHT_ENV` (§4).
///
/// `FLIGHT_ENV` is read exactly once, at the very start of bootstrap, and the
/// resulting `FlightEnvironment` is what selects `flight-{env}.yaml`. Nothing
/// downstream re-reads `FLIGHT_ENV` — if a module needs to branch on
/// environment, it reads a config value, not this enum. (Exception: Flight
/// Actuator, which legitimately needs the raw environment to decide whether
/// to expose itself at all — see the Flight Core introspection spec.)
///
/// `test` is a first-class case specifically so `flight-test.yaml` can exist
/// alongside `flight-dev.yaml` / `flight-prod.yaml` for integration-style
/// tests that want real config loading rather than `TestConfigSource`
/// overrides (§7).
public enum FlightEnvironment: String, Sendable, CaseIterable, Hashable {
    case dev, test, staging, prod

    /// Reads `FLIGHT_ENV` from the process environment. Defaults to `.dev`
    /// if unset — never throws, since "no environment specified" is a valid,
    /// common local-dev state. An unrecognized value also resolves to `.dev`,
    /// matching the design contract exactly; the values this recognizes are
    /// precisely the four raw cases, lowercase.
    public static func current() -> FlightEnvironment {
        current(from: ProcessInfo.processInfo.environment)
    }

    /// Same resolution as `current()`, against an explicit environment
    /// dictionary — the seam tests use instead of mutating the real process
    /// environment. `Configuration.load` routes through this with whatever
    /// `processEnvironment` it was handed, so the whole load path is
    /// reproducible from a plain dictionary.
    public static func current(from environment: [String: String]) -> FlightEnvironment {
        environment["FLIGHT_ENV"]
            .flatMap(FlightEnvironment.init(rawValue:)) ?? .dev
    }
}
