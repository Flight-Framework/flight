/// Errors thrown by `Configuration`'s typed accessors at *resolution* time.
///
/// These are the runtime-only failures of §5: a key whose presence couldn't
/// be proven statically (because it depends on `FLIGHT_ENV` or an environment
/// variable's actual runtime value) turned out to be missing or malformed.
/// They surface during bootstrap — a fast, loud startup failure, not a silent
/// nil discovered three services deep at request time.
///
/// Load-time failures (unreadable file, YAML syntax, unresolved `${VAR}`
/// substitution) are `ConfigLoadError` instead — they happen before a
/// `Configuration` exists at all.
public enum ConfigError: Error, CustomStringConvertible, Sendable {
    /// The key is absent from every source and no default was supplied.
    ///
    /// Carries the active environment when the `Configuration` was built by
    /// `Configuration.load` (nil for hand-assembled configurations, e.g. in
    /// tests) so the startup failure can name it, per §5: "a clear, specific
    /// error identifying the key and the active environment".
    case missingKey(key: String, environment: FlightEnvironment?)

    /// The key is present, but its raw string failed to decode as the
    /// requested type.
    case decodingFailed(key: String, rawValue: String, targetType: Any.Type)

    public var description: String {
        switch self {
        case .missingKey(let key, let environment):
            let envClause = environment.map { " (active environment: \($0.rawValue))" } ?? ""
            return """
            Configuration key '\(key)' is not set in any source\(envClause). \
            Add it to flight.yaml\(environment.map { " or flight-\($0.rawValue).yaml" } ?? ""), \
            or set the \(EnvironmentVariablesSource.variableName(for: key)) environment variable.
            """
        case .decodingFailed(let key, let rawValue, let targetType):
            return """
            Configuration key '\(key)' has value '\(rawValue)', \
            which is not a valid \(targetType).
            """
        }
    }
}

/// Errors thrown while *assembling* a `Configuration` from disk and the
/// process environment (§6 steps 2–3) — before any typed access happens.
public enum ConfigLoadError: Error, CustomStringConvertible, Sendable {
    /// `flight.yaml` — the base layer, expected in every environment (§3,
    /// §6 step 2) — was not found. Only the environment-specific
    /// `flight-{env}.yaml` is optional; an app configured purely by
    /// environment variables can assemble a `Configuration` directly from an
    /// `EnvironmentVariablesSource` instead of using `Configuration.load`.
    case missingBaseFile(expectedPath: String)

    /// The file exists but could not be read as UTF-8 text.
    case unreadableFile(path: String, reason: String)

    /// The file is not valid Flight-subset YAML. The message names the
    /// construct and, where the construct is deliberate (flow style, block
    /// scalars, anchors…), what to use instead.
    case parseFailed(file: String, line: Int, column: Int, message: String)

    /// A `${VAR}` substitution referenced an environment variable that is
    /// unset (and supplied no `${VAR:-default}` fallback). Failing the whole
    /// load here — rather than letting the key silently fall through to a
    /// lower-precedence layer — is deliberate: the alternative is a prod
    /// deployment quietly running on base-layer (dev) values.
    case unresolvedSubstitution(file: String, key: String, variable: String)

    public var description: String {
        switch self {
        case .missingBaseFile(let expectedPath):
            return """
            Base configuration file not found at '\(expectedPath)'. \
            flight.yaml is the base layer and must exist in every environment; \
            only flight-{env}.yaml overrides are optional.
            """
        case .unreadableFile(let path, let reason):
            return "Configuration file '\(path)' could not be read: \(reason)"
        case .parseFailed(let file, let line, let column, let message):
            return "\(file):\(line):\(column): \(message)"
        case .unresolvedSubstitution(let file, let key, let variable):
            return """
            \(file): key '\(key)' references environment variable '\(variable)' \
            via ${\(variable)}, which is not set. Set it, or use \
            ${\(variable):-default} to supply a fallback.
            """
        }
    }
}
