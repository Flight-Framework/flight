import FlightCore
import Foundation

/// Which consumer the dashboard is serving (§5): the shipped server-rendered
/// HTML, or the raw `ActuatorSnapshot` as JSON for a hand-rolled front-end.
/// One data set, two renderings — not two feature sets.
///
/// Configured as `actuator.format` in flight.yaml; absent means `.ssr`.
public enum ActuatorFormat: String, Sendable, CaseIterable, ConfigDecodable {
    case ssr
    case json

    /// Tolerates surrounding whitespace and case ("JSON", " ssr ") the same
    /// way the primitive `ConfigDecodable` conformances do; anything else is
    /// a decoding failure that fails bootstrap loudly rather than silently
    /// falling back to a default (Flight Config §5).
    public init?(configValue: String) {
        self.init(rawValue: configValue.trimmingCharacters(in: .whitespaces).lowercased())
    }
}
