/// Errors thrown by `Configuration`'s typed accessors at *resolution* time.
///
/// These are the runtime-only failures: a key whose presence couldn't
/// be proven statically (because it depends on `FLIGHT_ENV` or an environment
/// variable's actual runtime value) turned out to be missing or malformed.
/// They surface during bootstrap — a fast, loud startup failure, not a silent
/// nil discovered three services deep at request time.
///
/// Load-time failures (unreadable file, YAML syntax, unresolved `${VAR}`
/// substitution) are `ConfigLoadError` instead — they happen before a
/// `Configuration` exists at all.
public enum ConfigError: Error, CustomStringConvertible, Sendable, Equatable, Hashable {
    /// The key is absent from every source and no default was supplied.
    ///
    /// Carries the active environment when the `Configuration` was built by
    /// `Configuration.load` (nil for hand-assembled configurations, e.g. in
    /// tests) so the startup failure can identify both the key and the
    /// environment that was active when it could not be found.
    case missingKey(key: String, environment: FlightEnvironment?)

    /// The key is present, but its raw string failed to decode as the
    /// requested type.
    ///
    /// `targetType` is the type's name rather than its metatype, which is
    /// what lets this enum be `Equatable` and `Hashable` — and therefore
    /// usable in an adopter's test assertions.
    case decodingFailed(key: String, rawValue: String, targetType: String)

    /// The key is present in a provider, but holds a value with no single
    /// raw-string form — an array, or a byte blob.
    ///
    /// Resolution stops here rather than continuing to a lower-precedence
    /// layer. Falling through would answer a production key from a
    /// development layer without saying so, which is the one failure mode
    /// layered configuration must never have.
    ///
    /// Read these through `Configuration.reader` (in FlightConfig) and ask for the array
    /// type directly.
    case unrepresentableValue(key: String, provider: String, kind: String)

    /// A provider refused every shape the key was asked for without ever
    /// saying the key was absent — a secrets store that is down, a denied
    /// permission, a timed-out socket.
    ///
    /// Resolution stops here for the same reason
    /// ``unrepresentableValue(key:provider:kind:)`` does, and it matters
    /// more: a provider that fails looked exactly like a provider that is
    /// empty, so a transient failure in the secrets layer answered from the
    /// development YAML underneath it, silently and with the right-looking
    /// value.
    case providerFailed(key: String, provider: String, reason: String)

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
        case .providerFailed(let key, let provider, let reason):
            return """
                Configuration key '\(key)' could not be read from \(provider): \(reason). \
                Resolution stopped here rather than falling through to a lower-precedence \
                layer, which would answer with a value the failing layer was there to \
                override.
                """
        case .unrepresentableValue(let key, let provider, let kind):
            return """
            Configuration key '\(key)' is present in \(provider) as \(kind), \
            which has no single raw-string value. Resolution stopped here rather than \
            falling through to a lower-precedence layer. Read it through \
            Configuration.reader and request the array type directly.
            """
        }
    }
}

/// Errors thrown while *assembling* a `Configuration` from disk and the
/// process environment — before any typed access happens.
public enum ConfigLoadError: Error, CustomStringConvertible, Sendable, Equatable, Hashable {
    /// `flight.yaml` — the base layer, expected in every environment — was not found. Only the environment-specific
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
    case unresolvedSubstitution(file: String, line: Int, key: String, variable: String)

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
        case .unresolvedSubstitution(let file, let line, let key, let variable):
            return """
            \(file):\(line): key '\(key)' references environment variable '\(variable)' \
            via ${\(variable)}, which is not set. Set it, or use \
            ${\(variable):-default} to supply a fallback.
            """
        }
    }
}

import Foundation

extension ConfigError: LocalizedError {
    /// The same text as ``description``.
    ///
    /// Without this, `localizedDescription` — which most logging and
    /// error-reporting code reaches for — would discard the carefully
    /// written message and report a generic Foundation placeholder.
    public var errorDescription: String? { description }
}

extension ConfigLoadError: LocalizedError {
    /// The same text as ``description``.
    public var errorDescription: String? { description }
}
