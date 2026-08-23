import Configuration
import FlightConfigCore

/// Serves one already-parsed `FlightYAMLSnapshot`.
///
/// `FileProvider<FlightYAMLSnapshot>` is the general path and reads the file
/// itself, but its initializer is `async` — and Flight parses its layers
/// synchronously at bootstrap, before any concurrency exists. This
/// provider closes that gap: same snapshot, same lookup semantics, no `await`.
///
/// It is also the shape an embedder wants when the YAML did not come from a
/// file at all — a document baked into the binary, or one assembled in a test.
public struct FlightYAMLProvider: ConfigProvider {

    /// The document this provider serves.
    public let yamlSnapshot: FlightYAMLSnapshot

    public init(snapshot: FlightYAMLSnapshot) {
        self.yamlSnapshot = snapshot
    }

    /// Parses a document from a string and serves it.
    public init(
        string: String,
        name: String = "<inline yaml>",
        substitution: EnvironmentSubstitutionPolicy = .processEnvironment
    ) throws {
        self.yamlSnapshot = FlightYAMLSnapshot(
            document: try FlightYAMLDocument(
                string: string, name: name, substitution: substitution
            ),
            providerName: name
        )
    }

    public var providerName: String { yamlSnapshot.providerName }

    public func value(forKey key: AbsoluteConfigKey, type: ConfigType) throws -> LookupResult {
        try yamlSnapshot.value(forKey: key, type: type)
    }

    public func fetchValue(forKey key: AbsoluteConfigKey, type: ConfigType) async throws -> LookupResult {
        try yamlSnapshot.value(forKey: key, type: type)
    }

    public func watchValue<Return: ~Copyable>(
        forKey key: AbsoluteConfigKey,
        type: ConfigType,
        updatesHandler: nonisolated(nonsending) (
            _ updates: ConfigUpdatesAsyncSequence<Result<LookupResult, any Error>, Never>
        ) async throws -> Return
    ) async throws -> Return {
        // A parsed document never changes — emit once, then wait for
        // cancellation. `Configuration` is immutable post-bootstrap by design
        //; code wanting live updates uses ReloadingFileProvider, which
        // the FileConfigSnapshot conformance makes available for free.
        try await watchValueFromValue(forKey: key, type: type, updatesHandler: updatesHandler)
    }

    public func snapshot() -> any ConfigSnapshot {
        yamlSnapshot
    }

    public func watchSnapshot<Return: ~Copyable>(
        updatesHandler: nonisolated(nonsending) (_ updates: ConfigUpdatesAsyncSequence<any ConfigSnapshot, Never>) async throws -> Return
    ) async throws -> Return {
        try await watchSnapshotFromSnapshot(updatesHandler: updatesHandler)
    }
}

extension FlightYAMLProvider: CustomStringConvertible, CustomDebugStringConvertible {

    /// Names the file and how many keys it defines, without printing them.
    public var description: String {
        yamlSnapshot.description
    }

    /// The file's keys and values, sorted, with substituted values redacted.
    ///
    /// A literal written into the file is already disclosed by the file it
    /// lives in, so printing it discloses nothing new. A `${VAR}` placeholder
    /// is different: its resolved value came from the deployment environment,
    /// which is exactly where credentials live. Those render as `<REDACTED>`.
    ///
    /// ```swift
    /// // flight.yaml:  db: { host: localhost, password: "${DB_PASSWORD}" }
    /// String(reflecting: provider))
    /// // FlightYAML[flight.yaml, 2 keys: db.host=localhost, db.password=<REDACTED>]
    /// ```
    public var debugDescription: String {
        let document = yamlSnapshot.document
        let values = document.keys
            .sorted()
            .map { key -> String in
                if document.substitutedKeys.contains(key) {
                    return "\(key)=<REDACTED>"
                }
                return "\(key)=\(document.rawValue(for: key) ?? "")"
            }
            .joined(separator: ", ")
        return "FlightYAML[\(providerName), \(document.keys.count) keys: \(values)]"
    }
}
