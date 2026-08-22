import Foundation

/// How a `YAMLConfigSource` treats `${VAR}` placeholders in scalar values.
///
/// Substitution is a load-time convenience for referencing env vars from
/// static config (§8) — not a vault integration. It is a property of the
/// YAML layer specifically: environment variables *as a precedence layer*
/// are `EnvironmentVariablesSource`'s job and always win regardless.
public enum EnvironmentSubstitutionPolicy: Sendable {
    /// Resolve placeholders against a snapshot of the current process
    /// environment. The right policy at runtime, and the default.
    case processEnvironment

    /// Resolve placeholders against an explicit dictionary — tests, and
    /// loaders that were handed their environment.
    case resolve([String: String])

    /// Leave placeholders verbatim and never fail on them. For tooling that
    /// inspects config *structure* (the Flight Core build plugin checking
    /// `@ConfigValue` keys against `flight.yaml`) where build-machine env
    /// vars are meaningless. Never use this for values an app will consume.
    case none
}

/// `${VAR}` substitution over a single scalar value.
///
/// Grammar (bash-flavored, documented in the package README):
/// - `${VAR}` — replaced with the variable's value; **unset is an error**
///   (`ConfigLoadError.unresolvedSubstitution` at load time). Letting an
///   unset variable resolve to nothing would silently fall through to a
///   lower-precedence layer — e.g. prod quietly running on the base file's
///   dev URL — which is the exact failure §5 wants loud.
/// - `${VAR:-default}` — the variable's value, or `default` when the
///   variable is unset **or empty** (bash `:-` semantics). The default is
///   literal text; nesting is not supported.
/// - `$$` — a literal `$`.
/// - A `$` not followed by `{` is literal (`cost: $5` needs no escaping).
///
/// Variable names follow the POSIX shell form: `[A-Za-z_][A-Za-z0-9_]*`.
enum EnvironmentSubstitution {

    enum Failure: Error {
        case unresolved(variable: String)
        case syntax(message: String)
    }

    static func substitute(_ value: String, environment: [String: String]) throws -> String {
        guard value.contains("$") else { return value }

        var output = ""
        var index = value.startIndex
        while index < value.endIndex {
            let character = value[index]
            guard character == "$" else {
                output.append(character)
                index = value.index(after: index)
                continue
            }

            let next = value.index(after: index)
            if next < value.endIndex, value[next] == "$" {
                output.append("$")
                index = value.index(after: next)
                continue
            }
            guard next < value.endIndex, value[next] == "{" else {
                output.append("$")
                index = next
                continue
            }
            guard let close = value[next...].firstIndex(of: "}") else {
                throw Failure.syntax(message: "unterminated '${' substitution in '\(value)'")
            }

            let inner = String(value[value.index(after: next)..<close])
            let name: String
            let defaultValue: String?
            if let marker = inner.range(of: ":-") {
                name = String(inner[..<marker.lowerBound])
                defaultValue = String(inner[marker.upperBound...])
            } else {
                name = inner
                defaultValue = nil
            }

            guard isValidVariableName(name) else {
                if name.contains(":") {
                    throw Failure.syntax(
                        message: "unsupported substitution '${\(inner)}' — supported forms are ${VAR} and ${VAR:-default}"
                    )
                }
                throw Failure.syntax(
                    message: "invalid environment variable name '\(name)' in '${\(inner)}' (expected [A-Za-z_][A-Za-z0-9_]*)"
                )
            }

            let resolved = environment[name]
            if let defaultValue {
                // bash ':-': default applies when unset OR set-but-empty.
                if let resolved, !resolved.isEmpty {
                    output += resolved
                } else {
                    output += defaultValue
                }
            } else if let resolved {
                output += resolved
            } else {
                throw Failure.unresolved(variable: name)
            }
            index = value.index(after: close)
        }
        return output
    }

    private static func isValidVariableName(_ name: String) -> Bool {
        guard let first = name.first else { return false }
        guard first.isLetter && first.isASCII || first == "_" else { return false }
        return name.allSatisfy { ($0.isLetter || $0.isNumber) && $0.isASCII || $0 == "_" }
    }
}
