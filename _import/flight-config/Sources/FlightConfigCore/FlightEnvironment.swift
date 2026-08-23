import Foundation

/// The active deployment environment, resolved from `FLIGHT_ENV`.
///
/// `FLIGHT_ENV` is read once, at the start of bootstrap, and the result
/// selects which `flight-{env}.yaml` layers on top of the base file. Nothing
/// downstream re-reads it: code that needs to branch on environment reads a
/// configuration value instead.
///
/// ```swift
/// let environment = FlightEnvironment.current()   // FLIGHT_ENV=staging → .staging
/// ```
///
/// ## Adding your own
///
/// This is a `RawRepresentable` struct rather than an enum, so deployments
/// with environments beyond the four built-in ones can add them without
/// waiting on this package:
///
/// ```swift
/// extension FlightEnvironment {
///     static let qa = FlightEnvironment("qa")           // loads flight-qa.yaml
///     static let preproduction = FlightEnvironment("preproduction")
/// }
/// ```
///
/// A value that is not one of the built-ins is still a perfectly good
/// environment — ``current()`` returns it as itself rather than silently
/// collapsing it to ``dev``.
public struct FlightEnvironment: RawRepresentable, Sendable, Hashable, Codable {

    /// The environment name, as it appears in `FLIGHT_ENV` and in the
    /// `flight-{env}.yaml` filename.
    public let rawValue: String

    /// Creates an environment from its name.
    ///
    /// Never fails: any non-empty name is a valid environment, which is what
    /// makes the type extensible.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Creates an environment from its name.
    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    /// Local development. The default when `FLIGHT_ENV` is unset.
    public static let dev = FlightEnvironment("dev")

    /// Automated tests. A first-class environment so `flight-test.yaml` can
    /// sit alongside the others for integration-style tests that want real
    /// configuration loading rather than injected overrides.
    public static let test = FlightEnvironment("test")

    /// Pre-production.
    public static let staging = FlightEnvironment("staging")

    /// Production.
    public static let prod = FlightEnvironment("prod")

    /// The four environments this package defines.
    ///
    /// Not every valid environment — the type is extensible, so an app may
    /// define more. Use it to enumerate the built-ins, not to validate input.
    public static let standard: [FlightEnvironment] = [.dev, .test, .staging, .prod]

    /// Reads `FLIGHT_ENV` from the process environment.
    ///
    /// Defaults to ``dev`` when unset, since "no environment specified" is
    /// the normal local-development state.
    public static func current() -> FlightEnvironment {
        current(from: ProcessInfo.processInfo.environment)
    }

    /// Resolves `FLIGHT_ENV` from an explicit dictionary.
    ///
    /// The seam tests use instead of mutating the real process environment.
    /// `Configuration.load` routes through this, so the whole load path is
    /// reproducible from a plain dictionary.
    ///
    /// An unset or empty value resolves to ``dev``. Any other value resolves
    /// to itself — `FLIGHT_ENV=qa` gives you `qa`, and therefore
    /// `flight-qa.yaml`, rather than quietly loading development
    /// configuration under a production-shaped name.
    public static func current(from environment: [String: String]) -> FlightEnvironment {
        guard let raw = environment["FLIGHT_ENV"], !raw.isEmpty else {
            return .dev
        }
        return FlightEnvironment(raw)
    }
}

extension FlightEnvironment: CustomStringConvertible {
    public var description: String { rawValue }
}

extension FlightEnvironment: ExpressibleByStringLiteral {
    /// Lets an environment be written as a plain string literal where the
    /// type is already known.
    ///
    /// ```swift
    /// let environment: FlightEnvironment = "staging"
    /// ```
    public init(stringLiteral value: String) {
        self.rawValue = value
    }
}
