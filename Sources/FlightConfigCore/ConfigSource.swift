/// A single source of raw string values, ordered by precedence when combined
/// in a `Configuration`.
///
/// Sources never resolve types themselves — only `Configuration.get` does,
/// via `ConfigDecodable` (§2 of the design doc). A source's whole contract is
/// "given a dot-separated key, return the raw string you have for it, or nil".
///
/// Keys are flat, dot-separated paths (`datasource.url`, `server.port`).
/// Nested structure — YAML mappings, env-var name transforms — is each
/// source's private concern; by the time a key reaches `rawValue(for:)` it is
/// already flattened.
///
/// Conformances must be `Sendable` and immutable after construction:
/// `Configuration` is handed across the bootstrap boundary into arbitrary
/// concurrent resolution, and its immutability guarantee (§8) is only as good
/// as its sources'.
public protocol ConfigSource: Sendable {
    /// The raw string this source holds for `key`, or nil if the key is
    /// absent *from this source* (other sources may still supply it).
    func rawValue(for key: String) -> String?
}
