import Configuration
import FlightConfigCore

/// Adapts a Flight `ConfigSource` to a swift-configuration `ConfigProvider`.
///
/// Flight's source protocol is string-native and synchronous: "given a
/// dot-separated key, return the raw string you have for it, or nil". That is
/// a strict subset of what a provider does, so the bridge is mostly
/// mechanical — the interesting parts are the two places the contracts differ.
///
/// **Typing.** A source has no types; a provider is asked for one. Since the
/// source's answer is always a string, this provider converts on demand, which
/// makes `TestConfigSource(["server.port": "8080"])` answer an `.int` request
/// with `8080` — so a test source works with the swift-configuration reader
/// API, not just with Flight's accessors.
///
/// **Immutability.** Sources are immutable after construction (§8), so the
/// snapshot *is* the provider and every watch emits exactly one value and then
/// waits for cancellation. That is the correct semantics for a value that can
/// never change, and it is what `watchValueFromValue` / `watchSnapshotFromSnapshot`
/// implement — the helpers the provider-authoring guide points immutable
/// providers at.
struct ConfigSourceProvider: ConfigProvider {

    let source: any ConfigSource

    var providerName: String {
        "\(type(of: source))"
    }

    func value(forKey key: AbsoluteConfigKey, type: ConfigType) throws -> LookupResult {
        let encodedKey = key.components.joined(separator: ".")
        guard let raw = source.rawValue(for: encodedKey) else {
            return LookupResult(encodedKey: encodedKey, value: nil)
        }
        return LookupResult(
            encodedKey: encodedKey,
            value: try ConfigValue(flightRawString: raw, as: type, key: encodedKey)
        )
    }

    func fetchValue(forKey key: AbsoluteConfigKey, type: ConfigType) async throws -> LookupResult {
        try value(forKey: key, type: type)
    }

    func watchValue<Return: ~Copyable>(
        forKey key: AbsoluteConfigKey,
        type: ConfigType,
        updatesHandler: nonisolated(nonsending) (
            _ updates: ConfigUpdatesAsyncSequence<Result<LookupResult, any Error>, Never>
        ) async throws -> Return
    ) async throws -> Return {
        try await watchValueFromValue(forKey: key, type: type, updatesHandler: updatesHandler)
    }

    func snapshot() -> any ConfigSnapshot {
        ConfigSourceSnapshot(source: source, providerName: providerName)
    }

    func watchSnapshot<Return: ~Copyable>(
        updatesHandler: nonisolated(nonsending) (_ updates: ConfigUpdatesAsyncSequence<any ConfigSnapshot, Never>) async throws -> Return
    ) async throws -> Return {
        try await watchSnapshotFromSnapshot(updatesHandler: updatesHandler)
    }
}

/// The point-in-time view of a `ConfigSource` — which, a source being
/// immutable, is the source itself.
private struct ConfigSourceSnapshot: ConfigSnapshot {
    let source: any ConfigSource
    let providerName: String

    func value(forKey key: AbsoluteConfigKey, type: ConfigType) throws -> LookupResult {
        let encodedKey = key.components.joined(separator: ".")
        guard let raw = source.rawValue(for: encodedKey) else {
            return LookupResult(encodedKey: encodedKey, value: nil)
        }
        return LookupResult(
            encodedKey: encodedKey,
            value: try ConfigValue(flightRawString: raw, as: type, key: encodedKey)
        )
    }
}

extension ConfigValue {

    /// Converts a source's raw string into the requested `ConfigType`.
    ///
    /// Throws rather than returning nil on conversion failure, for the reason
    /// spelled out in `Configuration.rawValue(of:forKey:)`: nil means *absent*
    /// and lets a reader fall through to a lower-precedence layer, which would
    /// turn a malformed value into a silently-wrong one.
    init(flightRawString raw: String, as type: ConfigType, key: String) throws {
        switch type {
        case .string:
            self = .init(.string(raw), isSecret: false)
        case .int:
            guard let value = Int(configValue: raw) else {
                throw ConfigError.decodingFailed(key: key, rawValue: raw, targetType: Int.self)
            }
            self = .init(.int(value), isSecret: false)
        case .double:
            guard let value = Double(configValue: raw) else {
                throw ConfigError.decodingFailed(key: key, rawValue: raw, targetType: Double.self)
            }
            self = .init(.double(value), isSecret: false)
        case .bool:
            guard let value = Bool(configValue: raw) else {
                throw ConfigError.decodingFailed(key: key, rawValue: raw, targetType: Bool.self)
            }
            self = .init(.bool(value), isSecret: false)
        case .bytes:
            self = .init(.bytes([UInt8](raw.utf8)), isSecret: false)
        case .stringArray, .intArray, .doubleArray, .boolArray, .byteChunkArray:
            // A source's values are scalars; the flattened-sequence keys
            // (`hosts.0`) are addressable individually. Reassembling them is
            // FlightYAMLSnapshot's job, where the document structure is known.
            throw ConfigError.decodingFailed(key: key, rawValue: raw, targetType: [String].self)
        }
    }
}
