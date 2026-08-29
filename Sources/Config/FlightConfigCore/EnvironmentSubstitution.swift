/// How a `YAMLConfigSource` treats `${VAR}` placeholders in scalar values.
///
/// Substitution is a load-time convenience for referencing env vars from
/// static config — not a vault integration. It is a property of the
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
///   dev URL — which is exactly the failure that must be loud.
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
            // `range(of:)` was the file's only reason to import Foundation.
            // A two-character marker does not need it, and the package
            // advertises itself as dependency-lean.
            if let marker = Self.firstIndex(of: ":-", in: inner) {
                name = String(inner[..<marker])
                defaultValue = String(inner[inner.index(marker, offsetBy: 2)...])
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

    /// The first index of a two-character marker, stdlib-only.
    private static func firstIndex(of marker: String, in text: String) -> String.Index? {
        let characters = Array(marker)
        guard characters.count == 2 else { return nil }
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(after: index)
            guard next < text.endIndex else { return nil }
            if text[index] == characters[0] && text[next] == characters[1] { return index }
            index = next
        }
        return nil
    }

    private static func isValidVariableName(_ name: String) -> Bool {
        guard let first = name.first else { return false }
        guard first.isLetter && first.isASCII || first == "_" else { return false }
        return name.allSatisfy { ($0.isLetter || $0.isNumber) && $0.isASCII || $0 == "_" }
    }
}
