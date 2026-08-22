import Foundation

/// A `ConfigSource` backed by one Flight-subset YAML document — the shape of
/// precedence layers 2 and 3 (`flight-{env}.yaml`, `flight.yaml`).
///
/// Since the move onto swift-configuration the runtime path no longer goes
/// through this type: `Configuration.load` builds a
/// `FileProvider<FlightYAMLSnapshot>` instead, and both wrap the same
/// `FlightYAMLDocument`. It remains because it is public API, because a
/// `ConfigSource` is still the smallest possible way to hand-assemble a
/// `Configuration`, and because tooling that only wants a parsed file's keys
/// should not have to link a provider stack to get them.
public struct YAMLConfigSource: ConfigSource {

    /// The parsed document backing this source.
    public let document: FlightYAMLDocument

    /// Diagnostic name — the file name for file-backed sources. Appears in
    /// every error this source produces.
    public var name: String { document.name }

    /// Every flattened key this source holds.
    public var keys: Set<String> { document.keys }

    /// Wraps an already-parsed document.
    public init(document: FlightYAMLDocument) {
        self.document = document
    }

    /// Parses a YAML document from a string.
    ///
    /// - Parameters:
    ///   - string: The document text.
    ///   - name: Diagnostic name used in errors.
    ///   - substitution: How `${VAR}` placeholders are resolved. Defaults to
    ///     the process environment — the correct runtime behavior.
    public init(
        string: String,
        name: String = "<inline yaml>",
        substitution: EnvironmentSubstitutionPolicy = .processEnvironment
    ) throws {
        self.document = try FlightYAMLDocument(
            string: string, name: name, substitution: substitution
        )
    }

    /// Reads and parses a YAML file. Whether a *missing* file is an error is
    /// the caller's policy (§6), so this initializer only throws for files
    /// that exist but cannot be read or parsed — check existence first.
    public init(
        contentsOf url: URL,
        substitution: EnvironmentSubstitutionPolicy = .processEnvironment
    ) throws {
        self.document = try FlightYAMLDocument(contentsOf: url, substitution: substitution)
    }

    public func rawValue(for key: String) -> String? {
        document.rawValue(for: key)
    }
}
