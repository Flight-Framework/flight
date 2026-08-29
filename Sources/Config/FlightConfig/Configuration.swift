import struct Foundation.Date
import Configuration
import FlightConfigCore

/// Immutable, fully-resolved configuration. Built once at bootstrap, handed
/// into `Container.bootstrap()`, never mutated after.
///
/// A `Configuration` is an ordered stack of swift-configuration providers,
/// highest precedence first. Lookups walk the stack and the first provider
/// holding the key wins — which is what makes the layering (env vars over
/// `flight-{env}.yaml` over `flight.yaml`) a key-by-key merge rather than a
/// file-by-file one: a key present only in the base file still resolves even
/// when the environment file overrides its neighbors.
///
/// ## Why this is a facade and not a `ConfigReader` typealias
///
/// swift-configuration supplies the provider stack, the file/env/CLI/remote
/// providers, secret redaction, and access reporting. What it does not supply
/// is this library's failure contract: its optional and `default:` accessors
/// **swallow type-conversion errors**, returning nil or the default when a
/// value is present but malformed. That is precisely the silent-wrong-value
/// outcome this type exists to prevent, so it resolves through the provider
/// API directly — where a bad value is a thrown error — and applies Flight's
/// own `ConfigDecodable` on top.
///
/// Reach for `reader` when handing config to a library that speaks
/// swift-configuration; reach for `get`/`getIfPresent` for Flight's own code.
///
/// Fully `Sendable` and immutable: resolution is a side-effect-free read,
/// safe from any number of concurrent callers, no isolation required.
public struct Configuration: Sendable {

    /// Ordered highest-precedence first.
    private let providers: [any ConfigProvider]

    private let accessReporter: (any AccessReporter)?

    /// The environment this configuration was resolved for, when known.
    /// Set by `Configuration.load`; nil for hand-assembled configurations
    /// (tests, embedders composing their own stacks). Used to make
    /// `ConfigError.missingKey` name the active environment.
    public let environment: FlightEnvironment?

    /// Assembles a configuration from an ordered provider stack.
    ///
    /// The extension point for providers this package does not ship:
    /// any swift-configuration provider works here — `DirectoryFilesProvider`
    /// for Kubernetes secrets, `CommandLineArgumentsProvider`, a reloading
    /// file provider, or a third-party remote provider (AWS Secrets Manager,
    /// Vault) — without this package taking on a dependency for it.
    ///
    /// - Parameters:
    ///   - providers: Highest precedence first. The bootstrap order is
    ///     `[env vars, flight-{env}.yaml, flight.yaml]`.
    ///   - environment: The resolved `FlightEnvironment`, if this stack was
    ///     assembled for one. Purely diagnostic — it never affects lookups.
    ///   - accessReporter: Receives an event per resolved key — from Flight's
    ///     own accessors as well as from ``reader``, naming the call site and
    ///     every layer consulted on the way. Wire in `AccessLogger` to log
    ///     every config read, or a custom reporter to feed an Actuator-style
    ///     view. Values a layer marked secret — anything substituted from the
    ///     environment — carry that flag through, so a reporter that redacts
    ///     has something to redact on.
    public init(
        providers: [any ConfigProvider],
        environment: FlightEnvironment? = nil,
        accessReporter: (any AccessReporter)? = nil
    ) {
        self.providers = providers
        self.environment = environment
        self.accessReporter = accessReporter
    }

    /// Assembles a configuration from an ordered `ConfigSource` stack.
    ///
    /// Flight's own source protocol predates the move onto
    /// swift-configuration; each source is bridged to a provider here. Prefer
    /// `init(providers:)` for new code — it reaches the whole provider
    /// ecosystem — but nothing about this spelling has changed or needs to.
    public init(sources: [any ConfigSource], environment: FlightEnvironment? = nil) {
        self.init(
            providers: sources.map { ConfigSourceProvider(source: $0) },
            environment: environment
        )
    }

    /// Convenience for the common test/embedder case of a single in-memory
    /// layer: `Configuration(values: ["server.port": "8080"])` is exactly
    /// `Configuration(sources: [TestConfigSource(values)])`.
    public init(values: [String: String] = [:]) {
        self.init(sources: [TestConfigSource(values)])
    }

    // MARK: - Typed access

    /// Resolves and decodes a required key.
    ///
    /// ```swift
    /// let port: Int = try configuration.get("server.port")
    /// ```
    ///
    /// - Throws: `ConfigError.missingKey` if the key is
    ///   absent from every provider;
    ///   `ConfigError.decodingFailed` if it is
    ///   present but does not decode as `T`;
    ///   `ConfigError.unrepresentableValue` if a
    ///   provider holds it as an array or byte blob.
    public func get<T: ConfigDecodable>(
        _ key: String, as type: T.Type = T.self,
        fileID: String = #fileID, line: UInt = #line
    ) throws -> T {
        guard let raw = try resolveRawValue(for: key, fileID: fileID, line: line) else {
            throw ConfigError.missingKey(key: key, environment: environment)
        }
        return try decode(raw, key: key, as: type)
    }

    /// Resolves a key, falling back to `defaultValue` when it is absent.
    ///
    /// ```swift
    /// let port = configuration.get("server.port", default: 8080)
    /// ```
    ///
    /// - Important: This traps if the key is **present but malformed**, and
    ///   equally if it is present in a shape with no raw-string form, or if a
    ///   provider failed rather than answering. A corrupted value is not an
    ///   "optional config" situation, and silently substituting the default
    ///   would hide it — which is the failure mode this library exists to
    ///   prevent. The default applies to one case only: the key is genuinely
    ///   absent from every layer.
    ///
    ///   The value can come from the environment, so a deployment typo
    ///   (`FLIGHT_SERVER_PORT=eighty`) reaches this path and aborts the
    ///   process at startup. That is deliberate — a server that boots on the
    ///   wrong port is worse than one that refuses to boot — but if you need
    ///   to survive a malformed value, resolve it with
    ///   ``getIfPresent(_:as:fileID:line:)`` or ``get(_:as:fileID:line:)`` and handle the error:
    ///
    ///   ```swift
    ///   let port = (try? configuration.getIfPresent("server.port", as: Int.self)) ?? nil ?? 8080
    ///   ```
    public func get<T: ConfigDecodable>(
        _ key: String, default defaultValue: T,
        fileID: String = #fileID, line: UInt = #line
    ) -> T {
        let resolved: String?
        do {
            // Not `rawValue(for:)`. That swallows the throw, so a key present
            // as an array — or in a provider that is failing — came back as
            // nil and got the default: silently substituting for a present
            // value, on the one accessor documented to trap rather than mask.
            resolved = try resolveRawValue(for: key, fileID: fileID, line: line)
        } catch {
            fatalError(
                """
                Configuration key '\(key)' could not be resolved: \(error) \
                get(_:default:) applies the default only when the key is absent — it never \
                masks a value that is there but unreadable. Resolve the key with \
                getIfPresent/get(_:as:) and handle the error if this must be survivable.
                """)
        }
        guard let raw = resolved else {
            return defaultValue
        }
        guard let value = T(configValue: raw) else {
            fatalError("""
            Configuration key '\(key)' has value '\(raw)', which is not a valid \(T.self). \
            get(_:default:) applies the default only when the key is absent — it never masks \
            a malformed value. Fix the configured value, or resolve the key with \
            getIfPresent/get(_:as:) and handle ConfigError.decodingFailed yourself.
            """)
        }
        return value
    }

    /// Resolves an optional key without inventing a default.
    ///
    /// `nil` when the key is absent from every provider; throws when it is
    /// present but malformed. This is the shape for "absence means the
    /// feature is off" configuration — an optional TLS certificate path, an
    /// optional proxy URL — where there is no sensible default to supply.
    ///
    /// ```swift
    /// if let certPath: String = try configuration.getIfPresent("tls.certificate") {
    ///     enableTLS(at: certPath)
    /// }
    /// ```
    ///
    /// Unlike ``get(_:default:fileID:line:)`` this never traps, which is what makes it
    /// the right tool when a malformed value must be survivable.
    ///
    /// - Throws: `ConfigError.decodingFailed` or
    ///   `ConfigError.unrepresentableValue`.
    public func getIfPresent<T: ConfigDecodable>(
        _ key: String, as type: T.Type = T.self,
        fileID: String = #fileID, line: UInt = #line
    ) throws -> T? {
        guard let raw = try resolveRawValue(for: key, fileID: fileID, line: line) else {
            return nil
        }
        return try decode(raw, key: key, as: type)
    }

    // MARK: - Raw access

    /// The winning raw string for a key — first provider (highest precedence)
    /// holding it wins — or nil if absent everywhere. Typed access via `get`
    /// is the normal path; this exists for tooling and diagnostics (Flight
    /// Actuator's config view, error reporting) that work at the raw layer.
    ///
    /// Non-throwing, so it also answers nil for a key that is present in an
    /// unreadable shape or behind a failing provider. That is fine for a
    /// diagnostic display and wrong for resolution — use
    /// ``resolveRawValue(for:fileID:line:)`` anywhere the difference between "absent" and
    /// "could not be read" decides what happens next.
    public func rawValue(for key: String) -> String? {
        try? resolveRawValue(for: key)
    }

    /// The winning raw string for a key, or `nil` if absent everywhere.
    ///
    /// The throwing form of ``rawValue(for:)``. Throws
    /// `ConfigError.unrepresentableValue` when a
    /// provider holds the key as an array or byte blob, which has no single
    /// raw-string form.
    public func resolveRawValue(
        for key: String, fileID: String = #fileID, line: UInt = #line
    ) throws -> String? {
        let absoluteKey = AbsoluteConfigKey(Self.pathComponents(of: key))
        let encodedKey = absoluteKey.components.joined(separator: ".")
        // Only assembled when someone is listening: the walk is on the boot
        // path, and building an event per key for nobody is pure cost.
        var providerResults: [AccessEvent.ProviderResult] = []
        let reporter = accessReporter

        func note(_ provider: any ConfigProvider, _ result: Result<LookupResult, any Error>) {
            guard reporter != nil else { return }
            providerResults.append(
                .init(providerName: provider.providerName, result: result))
        }
        func report(_ outcome: Result<ConfigValue?, any Error>) {
            guard let reporter else { return }
            reporter.report(
                AccessEvent(
                    metadata: .init(
                        accessKind: .get,
                        key: absoluteKey,
                        // Flight resolves raw strings and decodes them itself,
                        // so `.string` is what the providers were actually
                        // asked for — the requested Swift type is not a
                        // `ConfigType` and would be a guess.
                        valueType: .string,
                        sourceLocation: .init(fileID: fileID, line: line),
                        accessTimestamp: Date()
                    ),
                    providerResults: providerResults,
                    result: outcome
                ))
        }

        for provider in providers {
            switch Self.lookup(of: provider, forKey: absoluteKey) {
            case .absent:
                note(provider, .success(LookupResult(encodedKey: encodedKey, value: nil)))
                continue
            case .resolved(let value, let raw):
                note(provider, .success(LookupResult(encodedKey: encodedKey, value: value)))
                report(.success(value))
                return raw
            case .unrepresentable(let kind):
                // Present here, but unreadable as a string. Stopping is the
                // whole point: continuing would answer from a lower layer.
                let error = ConfigError.unrepresentableValue(
                    key: key, provider: provider.providerName, kind: kind
                )
                note(provider, .failure(error))
                report(.failure(error))
                throw error
            case .failed(let underlying):
                let error = ConfigError.providerFailed(
                    key: key, provider: provider.providerName,
                    reason: String(describing: underlying)
                )
                note(provider, .failure(underlying))
                report(.failure(error))
                throw error
            }
        }
        report(.success(nil))
        return nil
    }

    /// Splits a dotted key into path components, rejecting empty ones.
    ///
    /// `split` alone silently drops empty components, so `a..b` and `a.b.`
    /// would both alias `a.b` — two different strings resolving to one key,
    /// which makes a typo indistinguishable from the key you meant.
    private static func pathComponents(of key: String) -> [String] {
        key.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    }

    /// Resolves one key against one provider, as a raw string.
    ///
    /// swift-configuration's lookup is *type-directed*: a provider is asked
    /// for a specific `ConfigType`, and one holding a typed value — a JSON or
    /// TOML integer, an `InMemoryProvider` `Int` — refuses a `.string`
    /// request outright rather than stringifying it. Flight decodes from raw
    /// strings, so asking only for `.string` would silently lose every
    /// non-string value in any file-backed or third-party provider.
    ///
    /// So: ask for `.string` first (the common case, and the only one Flight's
    /// own YAML snapshot ever needs), and on refusal retry the scalar types
    /// and render the winner. The round trip is lossless for every type
    /// `ConfigDecodable` supports.
    ///
    /// The nil/throw distinction carries the weight here and is worth stating
    /// plainly: **nil means the key is absent from this provider** and the
    /// walk moves on to the next layer, while **a throw means the key is
    /// present in a form this request could not read** and the walk must not
    /// fall through — falling through would resolve a prod key from a dev
    /// layer, silently.
    /// What one provider had to say about one key.
    private enum Lookup {
        /// Not in this provider at all — the walk continues.
        case absent
        /// A value this provider holds, with the raw string it renders as —
        /// the walk stops, successfully. The whole `ConfigValue` is kept, not
        /// just the string, because its `isSecret` flag is what an access
        /// reporter needs in order to redact.
        case resolved(ConfigValue, raw: String)
        /// Present, but with no single raw-string form. The walk stops and
        /// throws; it must not continue to a lower-precedence layer.
        case unrepresentable(String)
        /// The provider refused every shape it was asked for and never once
        /// answered "not here". Not the same as absent, and the walk stops
        /// for the same reason ``unrepresentable(_:)`` does.
        case failed(any Error)
    }

    private static func lookup(
        of provider: any ConfigProvider, forKey key: AbsoluteConfigKey
    ) -> Lookup {
        // A provider signals absence by *returning nil*, and a shape it
        // cannot serve by *throwing*. Every throw used to be swallowed by
        // `try?`, which collapsed the two: a provider that was down answered
        // exactly like a provider that was empty, and the walk fell through
        // to the layer below — resolving a production key from a development
        // one, silently, which the comment above calls the one failure mode
        // layered configuration must never have. So the refusals are kept:
        // if nothing ever answered *and* something threw, "absent" has not
        // been established and must not be assumed.
        //
        // Structural rather than error-typed on purpose. swift-configuration's
        // own error enum is `package`, and its provider contract says
        // implementations may throw "provider-specific errors" — so there is
        // nothing to match on, and a check that tried would work for the
        // built-in providers and quietly fail for exactly the third-party
        // ones this matters for.
        var refusal: (any Error)?

        // Flight's own providers know their key set outright, so a miss costs
        // one lookup rather than ten. That matters because absent keys are
        // not the rare case they sound like: `AdapterPresence` probes keys
        // that are *supposed* to be missing, and so does every
        // `getIfPresent` for an optional setting. A third-party provider has
        // no such shortcut and keeps the type-directed walk below, which is
        // correct — just slower.
        if let presence = provider as? any FlightKeyPresenceProvider,
            !presence.flightHoldsKey(key)
        {
            return .absent
        }

        // Scalars first: the common case, and the only shape Flight's own
        // YAML snapshot ever holds.
        for type in [ConfigType.string, .int, .double, .bool] {
            do {
                guard let value = try provider.value(forKey: key, type: type).value else {
                    continue  // The provider said: not here.
                }
                if let raw = value.content.flightRawString {
                    return .resolved(value, raw: raw)
                }
            } catch {
                if refusal == nil { refusal = error }
            }
        }

        // No scalar answered. That is either "absent" or "present as
        // something with no raw string" — and the difference decides whether
        // the walk may continue to a lower-precedence layer, so it has to be
        // established rather than assumed. A provider signals a type mismatch
        // by throwing, so absence can only be ruled out by asking for the
        // non-scalar shapes explicitly.
        let nonScalarTypes: [ConfigType] = [
            .stringArray, .intArray, .doubleArray, .boolArray, .bytes, .byteChunkArray,
        ]
        for type in nonScalarTypes {
            do {
                guard try provider.value(forKey: key, type: type).value != nil else { continue }
                return .unrepresentable(type.flightKindDescription)
            } catch {
                if refusal == nil { refusal = error }
            }
        }

        // Ten refusals and not one "not here": whatever this provider is
        // doing, it is not telling us the key is absent.
        if let refusal { return .failed(refusal) }
        return .absent
    }

    private func decode<T: ConfigDecodable>(_ raw: String, key: String, as type: T.Type) throws -> T {
        guard let value = T(configValue: raw) else {
            throw ConfigError.decodingFailed(key: key, rawValue: raw, targetType: String(describing: type))
        }
        return value
    }

    // MARK: - swift-configuration interop

    /// This configuration as a swift-configuration `ConfigReader`.
    ///
    /// The handoff for libraries that take a `ConfigReader` — Vapor,
    /// Hummingbird, and the Swift Temporal SDK all do — so a Flight app
    /// configures them from the same layered stack that configures Flight,
    /// rather than maintaining a second one.
    ///
    /// Note the semantic difference at the boundary: a reader's optional and
    /// `default:` accessors swallow malformed values where `get`/`getIfPresent`
    /// fail loudly. That is the reader's contract, not a defect — but it is
    /// why Flight's own code should not resolve config through this property.
    public var reader: ConfigReader {
        ConfigReader(providers: providers, accessReporter: accessReporter)
    }
}

extension Configuration: CustomStringConvertible {

    /// The provider stack, highest precedence first — what an operator wants
    /// when a key resolved to something surprising and the question is *which
    /// layer said so*.
    ///
    /// Each provider summarizes itself — how many values it holds, which file
    /// it came from — without printing any of them, so this is safe to log
    /// unconditionally. Use `debugDescription` for the values.
    public var description: String {
        render { "\($0)" }
    }

    private func render(_ describe: (any ConfigProvider) -> String) -> String {
        let stack = providers
            .enumerated()
            .map { "  \($0.offset + 1). \(describe($0.element))" }
            .joined(separator: "\n")
        let environmentClause = environment.map { " (environment: \($0.rawValue))" } ?? ""
        return "Configuration\(environmentClause), \(providers.count) providers, highest precedence first:\n\(stack)"
    }
}

extension Configuration: CustomDebugStringConvertible {

    /// The provider stack *with* the values each layer holds — what actually
    /// answers "which layer said so, and what did it say".
    ///
    /// Values marked secret render as `<REDACTED>`. That redaction is each
    /// provider's own responsibility (see `Configuration.load(secrets:)`), so
    /// it holds only for values a provider was told are sensitive: marking
    /// them is what makes this safe to put in a diagnostic dump.
    public var debugDescription: String {
        render { String(reflecting: $0) }
    }
}

extension ConfigContent {

    /// The raw-string rendering Flight's `ConfigDecodable` decodes from.
    ///
    /// Scalars only: an array or byte blob has no single raw string, and a
    /// caller wanting those should go through `reader` and ask for the array
    /// type directly.
    fileprivate var flightRawString: String? {
        switch self {
        case .string(let value): return value
        case .int(let value): return String(value)
        case .double(let value): return String(value)
        case .bool(let value): return String(value)
        case .bytes, .stringArray, .intArray, .doubleArray, .boolArray, .byteChunkArray:
            return nil
        }
    }

}

extension ConfigType {

    /// A human name for the shape, for the error a non-scalar value raises.
    ///
    /// This lived on `ConfigContent` with no callers at all while `lookup`
    /// carried the same ten strings inline — two tables of one thing, one of
    /// them unread. Here it has the caller.
    fileprivate var flightKindDescription: String {
        switch self {
        case .string: return "a string"
        case .int: return "an integer"
        case .double: return "a double"
        case .bool: return "a boolean"
        case .bytes: return "a byte blob"
        case .stringArray: return "an array of strings"
        case .intArray: return "an array of integers"
        case .doubleArray: return "an array of doubles"
        case .boolArray: return "an array of booleans"
        case .byteChunkArray: return "an array of byte blobs"
        }
    }
}
