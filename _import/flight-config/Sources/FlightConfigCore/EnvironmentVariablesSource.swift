import Foundation

/// The environment-variable layer — precedence layer 1, the layer that always
/// wins. It is the standard "override anything at deploy time" escape
/// hatch: container orchestrators, CI secrets, one-off local overrides.
///
/// Keys map to variable names via a fixed transform: uppercase, `.` → `_`,
/// prefixed `FLIGHT_`. So `datasource.url` reads `FLIGHT_DATASOURCE_URL`,
/// and `datasource.pool_size` reads `FLIGHT_DATASOURCE_POOL_SIZE`.
///
/// Two consequences of the transform being fixed and one-way:
///
/// - Config keys should stick to lowercase letters, digits, underscores, and
///   dots — anything else (dashes, say) produces a variable name most shells
///   cannot set.
/// - The transform is not injective: `datasource.pool_size` and
///   `datasource.pool.size` both read `FLIGHT_DATASOURCE_POOL_SIZE`. Spring's
///   relaxed binding has the same property; don't define config keys that
///   collide under it.
///
/// The process environment is snapshotted at `init` — the source never
/// re-reads `ProcessInfo` afterwards, preserving `Configuration`'s
/// immutability guarantee even if something else mutates the
/// environment mid-flight.
public struct EnvironmentVariablesSource: ConfigSource {
    private let environment: [String: String]

    /// - Parameter environment: The variables to read, defaulting to a
    ///   snapshot of the current process environment. Tests pass a plain
    ///   dictionary instead of mutating the real one.
    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
    }

    public func rawValue(for key: String) -> String? {
        environment[Self.variableName(for: key)]
    }

    /// The fixed key → variable-name transform: uppercase, `.` → `_`,
    /// prefixed `FLIGHT_`. Public so error messages and docs can tell users
    /// exactly which variable would satisfy a key.
    public static func variableName(for key: String) -> String {
        "FLIGHT_" + key.uppercased().replacingOccurrences(of: ".", with: "_")
    }
}
