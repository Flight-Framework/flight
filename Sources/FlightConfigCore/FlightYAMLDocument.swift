import Foundation

/// One Flight-subset YAML document, parsed, flattened to dot-separated keys,
/// and `${VAR}`-substituted — all of it once, at construction.
///
/// This is the unit of work both consumers of the parser share: the runtime
/// (via `FlightYAMLSnapshot`, wrapped in a swift-configuration `FileProvider`)
/// and Flight Core's build plugin (which reads `keys` to check `@ConfigValue`
/// sites against `flight.yaml`). Keeping it here, in the dependency-free core,
/// is what guarantees build time and runtime can never disagree about what
/// keys a file defines.
///
/// Every way a file can be wrong — syntax, out-of-subset constructs,
/// unresolved substitutions, colliding keys — throws a `ConfigLoadError` from
/// this initializer, before any `Configuration` exists: the fast, loud
/// startup failure §5 calls for.
public struct FlightYAMLDocument: Sendable, Hashable {

    /// Diagnostic name — the file name for file-backed documents. Appears in
    /// every error this document produces.
    public let name: String

    private let values: [String: String]

    /// Every flattened key this document holds. Exposed for tooling: the
    /// Flight Core build plugin checks `@ConfigValue` keys against the base
    /// file's key set at compile time (§5), and Actuator-style dashboards
    /// enumerate layers.
    public var keys: Set<String> {
        Set(values.keys)
    }

    /// Parses a document from a string.
    ///
    /// - Parameters:
    ///   - string: The document text.
    ///   - name: Diagnostic name used in errors.
    ///   - substitution: How `${VAR}` placeholders are resolved. Defaults to
    ///     the process environment — the correct runtime behavior. The build
    ///     plugin passes `.none`: build-machine env vars are meaningless to a
    ///     check that only needs the key structure.
    public init(
        string: String,
        name: String = "<inline yaml>",
        substitution: EnvironmentSubstitutionPolicy = .processEnvironment
    ) throws {
        self.name = name

        let root: FlightYAML.Node?
        let flat: [FlightYAML.FlatEntry]
        do {
            root = try FlightYAML.parse(string)
            flat = try root.map(FlightYAML.flatten) ?? []
        } catch let error as FlightYAML.ParseError {
            throw ConfigLoadError.parseFailed(
                file: name, line: error.line, column: error.column, message: error.message
            )
        }

        let environment: [String: String]?
        switch substitution {
        case .processEnvironment:
            environment = ProcessInfo.processInfo.environment
        case .resolve(let explicit):
            environment = explicit
        case .none:
            environment = nil
        }

        var resolved: [String: String] = [:]
        resolved.reserveCapacity(flat.count)
        for entry in flat {
            guard let environment else {
                resolved[entry.key] = entry.value
                continue
            }
            do {
                resolved[entry.key] = try EnvironmentSubstitution.substitute(
                    entry.value, environment: environment
                )
            } catch let failure as EnvironmentSubstitution.Failure {
                switch failure {
                case .unresolved(let variable):
                    throw ConfigLoadError.unresolvedSubstitution(
                        file: name, key: entry.key, variable: variable
                    )
                case .syntax(let message):
                    throw ConfigLoadError.parseFailed(
                        file: name, line: entry.line, column: 1, message: message
                    )
                }
            }
        }
        self.values = resolved
    }

    /// Reads and parses a file. Whether a *missing* file is an error is the
    /// caller's policy (§6: a missing `flight-{env}.yaml` is fine, a missing
    /// `flight.yaml` is not), so this initializer only throws for files that
    /// exist but cannot be read or parsed — check existence first.
    public init(
        contentsOf url: URL,
        substitution: EnvironmentSubstitutionPolicy = .processEnvironment
    ) throws {
        let name = url.lastPathComponent
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw ConfigLoadError.unreadableFile(path: url.path, reason: "\(error)")
        }
        try self.init(string: text, name: name, substitution: substitution)
    }

    /// The raw string this document holds for `key`, or nil if absent.
    public func rawValue(for key: String) -> String? {
        values[key]
    }

    /// The elements of a flattened sequence at `key` — the contiguous run of
    /// `key.0`, `key.1`, … — or nil if this document has no sequence there.
    ///
    /// Sequences flatten by index rather than staying structured (§ the YAML
    /// subset), so this is what reassembles them for callers that want an
    /// array. A `key.0` with no `key.1` is a one-element array, which is
    /// indistinguishable from a one-element sequence in the source — and is
    /// exactly what the source said.
    public func arrayElements(for key: String) -> [String]? {
        guard values["\(key).0"] != nil else { return nil }
        var elements: [String] = []
        var index = 0
        while let element = values["\(key).\(index)"] {
            elements.append(element)
            index += 1
        }
        return elements
    }
}
