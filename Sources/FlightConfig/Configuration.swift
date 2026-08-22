import Configuration
import FlightConfigCore

/// Immutable, fully-resolved configuration. Built once at bootstrap, handed
/// into `Container.bootstrap()`, never mutated after (§2).
///
/// A `Configuration` is an ordered stack of swift-configuration providers,
/// highest precedence first. Lookups walk the stack and the first provider
/// holding the key wins — which is what makes the §3 layering (env vars over
/// `flight-{env}.yaml` over `flight.yaml`) a key-by-key merge rather than a
/// file-by-file one: a key present only in the base file still resolves even
/// when the environment file overrides its neighbors.
///
/// ## Why this is a facade and not a `ConfigReader` typealias
///
/// swift-configuration supplies the provider stack, the file/env/CLI/remote
/// providers, secret redaction, and access reporting. What it does not supply
/// is Flight's §5 failure contract: its optional and `default:` accessors
/// **swallow type-conversion errors**, returning nil or the default when a
/// value is present but malformed. That is precisely the silent-wrong-value
/// outcome §5 exists to prevent, so this type resolves through the provider
/// API directly — where a bad value is a thrown error — and applies Flight's
/// own `ConfigDecodable` on top.
///
/// Reach for `reader` when handing config to a library that speaks
/// swift-configuration; reach for `get`/`getIfPresent` for Flight's own code.
///
/// Fully `Sendable` and immutable (§8): resolution is a side-effect-free read,
/// safe from any number of concurrent callers, no isolation required.
public struct Configuration: Sendable {

    /// Ordered highest-precedence first.
    private let providers: [any ConfigProvider]

    private let accessReporter: (any AccessReporter)?

    /// The environment this configuration was resolved for, when known.
    /// Set by `Configuration.load`; nil for hand-assembled configurations
    /// (tests, embedders composing their own stacks). Used to make
    /// `ConfigError.missingKey` name the active environment (§5).
    public let environment: FlightEnvironment?

    /// Assembles a configuration from an ordered provider stack.
    ///
    /// This is the extension point §8 promised and could not deliver in v1:
    /// any swift-configuration provider works here — `DirectoryFilesProvider`
    /// for Kubernetes secrets, `CommandLineArgumentsProvider`, a reloading
    /// file provider, or a third-party remote provider (AWS Secrets Manager,
    /// Vault) — without this package taking on a dependency for it.
    ///
    /// - Parameters:
    ///   - providers: Highest precedence first. The §6 bootstrap order is
    ///     `[env vars, flight-{env}.yaml, flight.yaml]`.
    ///   - environment: The resolved `FlightEnvironment`, if this stack was
    ///     assembled for one. Purely diagnostic — it never affects lookups.
    ///   - accessReporter: Receives an event per resolved key. Wire in
    ///     `AccessLogger` to log every config read, or a custom reporter to
    ///     feed an Actuator-style view.
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
    /// Throws `ConfigError.missingKey` if the key is absent from every
    /// provider and no default is supplied. Throws
    /// `ConfigError.decodingFailed` if the key is present but its raw string
    /// fails to decode as `T` (§2).
    public func get<T: ConfigDecodable>(_ key: String, as type: T.Type = T.self) throws -> T {
        guard let raw = rawValue(for: key) else {
            throw ConfigError.missingKey(key: key, environment: environment)
        }
        return try decode(raw, key: key, as: type)
    }

    /// Non-throwing variant for genuinely optional config (§2): returns
    /// `defaultValue` when the key is absent from every provider.
    ///
    /// A key that is *present but malformed* is not an "optional config"
    /// situation — it is a corrupted configuration, and silently substituting
    /// the default would mask it (the exact silent-`nil`-three-services-deep
    /// failure mode §5 exists to prevent). That case traps with a message
    /// naming the key, value, and type. Code that genuinely needs to tolerate
    /// a malformed value uses `getIfPresent` (throwing) or `get(_:as:)` and
    /// handles the error itself.
    public func get<T: ConfigDecodable>(_ key: String, default defaultValue: T) -> T {
        guard let raw = rawValue(for: key) else {
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

    /// Resolves an optional key without inventing a default: nil when the key
    /// is absent from every provider, `ConfigError.decodingFailed` when
    /// present but malformed.
    ///
    /// This is the shape for "absence means the feature is off" config (an
    /// optional TLS cert path, an optional proxy URL) where no default value
    /// exists to hand `get(_:default:)` — and it is what the `@ConfigValue`
    /// macro's `default:` expansion resolves through, so a malformed value
    /// still fails module configuration loudly instead of trapping.
    public func getIfPresent<T: ConfigDecodable>(_ key: String, as type: T.Type = T.self) throws -> T? {
        guard let raw = rawValue(for: key) else {
            return nil
        }
        return try decode(raw, key: key, as: type)
    }

    // MARK: - Raw access

    /// The winning raw string for a key — first provider (highest precedence)
    /// holding it wins — or nil if absent everywhere. Typed access via `get`
    /// is the normal path; this exists for tooling and diagnostics (Flight
    /// Actuator's config view, error reporting) that work at the raw layer.
    public func rawValue(for key: String) -> String? {
        let absoluteKey = AbsoluteConfigKey(key.split(separator: ".").map(String.init))
        for provider in providers {
            if let raw = Self.rawValue(of: provider, forKey: absoluteKey) {
                return raw
            }
        }
        return nil
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
    private static func rawValue(
        of provider: any ConfigProvider, forKey key: AbsoluteConfigKey
    ) -> String? {
        for type in [ConfigType.string, .int, .double, .bool] {
            guard let result = try? provider.value(forKey: key, type: type) else {
                // Present, but not readable as `type` — try another shape.
                continue
            }
            guard let value = result.value else {
                // Genuinely absent from this provider, whatever the type.
                continue
            }
            if let raw = value.content.flightRawString {
                return raw
            }
        }
        return nil
    }

    private func decode<T: ConfigDecodable>(_ raw: String, key: String, as type: T.Type) throws -> T {
        guard let value = T(configValue: raw) else {
            throw ConfigError.decodingFailed(key: key, rawValue: raw, targetType: type)
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
