import FlightConfigCore
import FlightCore
import Foundation

/// How much of the actuator this deployment publishes.
///
/// The gate used to be `environment != .prod`, which fails **open**: an unset
/// `FLIGHT_ENV` resolves to `dev`, and any spelling the code does not
/// recognize — `production`, `PROD`, `prd` — is also not `.prod`. Both
/// published the full topology endpoint, unauthenticated, on a production
/// deployment whose operator believed otherwise.
///
/// The decision is an allowlist now. Only environments known to be
/// development get the dashboard; everything else, including anything
/// unrecognized, gets the health endpoint and nothing more. Getting the
/// environment name wrong now costs a dashboard rather than leaking one.
public enum ActuatorExposure: String, Sendable, CaseIterable {
    /// No actuator routes at all.
    case disabled
    /// `/actuator/health` only: a liveness answer with no topology in it.
    ///
    /// The default outside development. Orchestrators need a probe endpoint
    /// in production — blocking that was why the old all-or-nothing gate
    /// left production with no health check at all.
    case healthOnly = "health_only"
    /// `/actuator/health` plus the `/actuator` dashboard, which discloses the
    /// module list, every registered component's fully-qualified type name,
    /// and failure messages. Development only unless something in front of it
    /// requires authentication.
    case full

    /// Environments that get the dashboard without being asked twice.
    static let developmentEnvironments: Set<String> = ["dev", "development", "test", "local"]

    /// Resolves the exposure for `environment`, honoring an explicit
    /// `FLIGHT_ACTUATOR_EXPOSURE` override.
    ///
    /// Read from the process environment rather than `flight.yaml`, for the
    /// same reason `FLIGHT_ENV` is: this decides whether a route is
    /// *registered at all*, and registration happens before configuration is
    /// resolvable. `FLIGHT_ACTUATOR_EXPOSURE` is the env-var spelling of
    /// `actuator.exposure` under Flight Config's own naming convention, so it
    /// is the same key, given the only way it can be given this early.
    ///
    /// An unrecognized value throws rather than falling back: a typo in the
    /// setting that controls disclosure should stop the app, not quietly
    /// choose for it.
    /// - Parameters:
    ///   - environment: The resolved environment.
    ///   - isEnvironmentDeclared: Whether that environment was *stated* —
    ///     `FLIGHT_ENV` set, or an embedder naming it in code — as opposed to
    ///     defaulted. See the discussion below; a default is not a
    ///     declaration.
    ///   - processEnvironment: Where the `FLIGHT_ACTUATOR_EXPOSURE` override
    ///     is read from.
    public static func resolve(
        environment: FlightEnvironment,
        isEnvironmentDeclared: Bool = true,
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> ActuatorExposure {
        if let raw = processEnvironment["FLIGHT_ACTUATOR_EXPOSURE"], !raw.isEmpty {
            guard let exposure = ActuatorExposure(rawValue: raw.lowercased()) else {
                throw ActuatorConfigurationError.unknownExposure(
                    value: raw, supported: ActuatorExposure.allCases.map(\.rawValue))
            }
            return exposure
        }
        // An unset `FLIGHT_ENV` resolves to `dev`, and `dev` is in the
        // allowlist — so a production deployment that simply never set the
        // variable served the full unauthenticated dashboard. That is
        // byte-for-byte the fail-open half of the gate this allowlist
        // replaced: the allowlist closed the misspelled-name half and left
        // this one open, while the docs claimed getting the environment name
        // wrong "costs you a dashboard instead of leaking one".
        //
        // A default is not a declaration. Saying nothing gets the safe
        // answer, and a development machine that wants the dashboard says so
        // — `FLIGHT_ENV=dev`, or the override.
        guard isEnvironmentDeclared else { return .healthOnly }
        return developmentEnvironments.contains(environment.rawValue.lowercased())
            ? .full : .healthOnly
    }

    var publishesDashboard: Bool { self == .full }
    var publishesHealth: Bool { self != .disabled }
}

/// A malformed `actuator.*` setting, raised at configuration time.
public enum ActuatorConfigurationError: Error, CustomStringConvertible {
    case unknownExposure(value: String, supported: [String])

    public var description: String {
        switch self {
        case .unknownExposure(let value, let supported):
            return """
                actuator.exposure is "\(value)"; expected one of \
                \(supported.joined(separator: ", ")).
                """
        }
    }
}
