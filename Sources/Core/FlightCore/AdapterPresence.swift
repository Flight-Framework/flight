/// Compose-by-presence, cross-checked against configuration.
///
/// Several Flight features pick their implementation by whether an adapter
/// module registered one: PubSub is single-node unless a distributed adapter
/// is present, the cache is in-process unless a shared store is. That default
/// is right — the common deployment is one node, and it should not have to
/// name a module it does not use.
///
/// The failure mode is the other direction. Configuration says
/// `cache.valkey.url`, the module list does not say `FlightCacheValkeyModule`,
/// and the fallback quietly does its job: the app boots, every test passes,
/// each node caches privately, and the first symptom is two users seeing
/// different numbers in production. Nothing was misconfigured badly enough to
/// fail — the configuration was simply read by nobody.
///
/// This is the check for that. A feature that falls back calls it with the
/// keys that would only be there if someone wanted the adapter, and an
/// unread block becomes a bootstrap failure naming the module to add.
extension Configuration {
    /// Fails when configuration asks for an adapter whose module was not loaded.
    ///
    /// Call from the fallback branch only — the adapter being present is the
    /// case where the configuration was read, and there is nothing to warn
    /// about.
    ///
    /// ```swift
    /// guard case .notRegistered = error else { throw error }
    /// try configuration.requireNoUnloadedAdapter(
    ///     feature: "cache",
    ///     candidates: [.init(configurationKey: "cache.valkey.url", module: "FlightCacheValkeyModule")])
    /// return try container.resolve(InMemoryCache.self)
    /// ```
    ///
    /// - Parameters:
    ///   - feature: What fell back, named as a user would say it ("cache").
    ///   - candidates: One entry per adapter this feature can compose with.
    ///     The key should be one the adapter *requires*, so its presence is
    ///     unambiguous intent rather than a leftover tuning knob.
    /// - Throws: ``UnloadedAdapterError`` for the first candidate configured.
    public func requireNoUnloadedAdapter(
        feature: String,
        candidates: [AdapterCandidate]
    ) throws {
        for candidate in candidates where isPresent(candidate.configurationKey) {
            throw UnloadedAdapterError(
                feature: feature,
                configurationKey: candidate.configurationKey,
                module: candidate.module)
        }
    }

    /// Whether any provider holds the key, regardless of whether it decodes.
    ///
    /// A key held as an array or byte blob throws from
    /// `resolveRawValue(for:)` rather than returning a string. A provider that
    /// fails throws too, and that also counts as present here. For this
    /// question that still counts as present — the operator wrote something
    /// there, which is the whole signal.
    private func isPresent(_ key: String) -> Bool {
        do {
            return try resolveRawValue(for: key) != nil
        } catch {
            return true
        }
    }
}

/// One adapter a feature can compose with, and the configuration key that
/// means somebody wanted it.
public struct AdapterCandidate: Sendable, Equatable {
    /// A key the adapter requires — its URL, not one of its tuning knobs.
    public let configurationKey: String
    /// The module type name to add to `Flight.bootstrap(modules:)`.
    public let module: String

    public init(configurationKey: String, module: String) {
        self.configurationKey = configurationKey
        self.module = module
    }
}

/// Configuration named an adapter that no loaded module provides.
///
/// Thrown at `freeze()`, so it stops the process at startup rather than
/// letting it serve traffic from a fallback nobody asked for.
public struct UnloadedAdapterError: Error, Sendable, Equatable, CustomStringConvertible {
    public let feature: String
    public let configurationKey: String
    public let module: String

    public init(feature: String, configurationKey: String, module: String) {
        self.feature = feature
        self.configurationKey = configurationKey
        self.module = module
    }

    public var description: String {
        """
        Configuration sets '\(configurationKey)', but \(module) is not in the module list, so \
        \(feature) fell back to its single-node default and that configuration would never be \
        read. Add \(module) to Flight.bootstrap(modules:), or remove the '\(configurationKey)' \
        configuration if the fallback is what you want.
        """
    }
}
