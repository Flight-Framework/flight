import Foundation

/// A type that can be decoded from a single raw configuration string.
///
/// Conformances ship for the obvious primitives (`String`, `Int`, `Bool`,
/// `Double`, `URL`) out of the box (§2). Custom types conform the same way
/// any `Codable`-adjacent type would in Swift — implement the failable
/// initializer, return nil on malformed input, and `Configuration.get`
/// converts that nil into a `ConfigError.decodingFailed` naming the key, the
/// raw value, and the target type:
///
/// ```swift
/// enum LogLevel: String, ConfigDecodable {
///     case debug, info, warn, error
///     init?(configValue: String) { self.init(rawValue: configValue) }
/// }
/// ```
public protocol ConfigDecodable {
    /// Creates a value from the raw string a `ConfigSource` returned.
    /// Return nil if the string is not a valid representation.
    init?(configValue: String)
}

// MARK: - Standard conformances

extension String: ConfigDecodable {
    /// Every raw string is a valid `String` — including the empty string
    /// (an explicitly-quoted `""` in YAML, or an empty env var).
    public init?(configValue: String) {
        self = configValue
    }
}

extension Int: ConfigDecodable {
    /// Base-10 integer. Surrounding whitespace is tolerated (env vars and
    /// hand-edited files pick up stray spaces easily); anything else —
    /// grouping separators, hex prefixes, fractions — is not.
    public init?(configValue: String) {
        self.init(configValue.configTrimmed)
    }
}

extension Double: ConfigDecodable {
    /// Anything `Double.init(String)` accepts: plain decimals and scientific
    /// notation (`1.5`, `1e3`). Surrounding whitespace is tolerated.
    public init?(configValue: String) {
        self.init(configValue.configTrimmed)
    }
}

extension Bool: ConfigDecodable {
    /// Accepts the YAML-1.1-style boolean spellings, case-insensitively:
    /// `true`/`false`, `yes`/`no`, `on`/`off`, plus `1`/`0` (the common
    /// env-var convention). Anything else is a decoding failure — a value
    /// like `"enabled"` should fail loudly, not guess.
    public init?(configValue: String) {
        switch configValue.configTrimmed.lowercased() {
        case "true", "yes", "on", "1":
            self = true
        case "false", "no", "off", "0":
            self = false
        default:
            return nil
        }
    }
}

extension URL: ConfigDecodable {
    /// Anything `URL.init(string:)` accepts, after trimming surrounding
    /// whitespace and rejecting the empty string. No scheme requirement —
    /// relative file paths are legitimate config values.
    public init?(configValue: String) {
        let trimmed = configValue.configTrimmed
        guard !trimmed.isEmpty else { return nil }
        self.init(string: trimmed)
    }
}

extension String {
    /// Whitespace-trimming shared by the non-String conformances. `String`
    /// itself deliberately does not trim — raw values pass through intact.
    var configTrimmed: String {
        trimmingCharacters(in: .whitespaces)
    }
}
