import Configuration
import FlightConfigCore

/// Flight-subset YAML as a swift-configuration snapshot.
///
/// This is the seam that puts Flight's parser inside Apple's provider
/// machinery. Conforming to `FileConfigSnapshot` — rather than writing a
/// `ConfigProvider` by hand — is what the provider-authoring guide prescribes
/// for file formats, and it yields two providers for one conformance:
///
/// ```swift
/// FileProvider<FlightYAMLSnapshot>(filePath: "flight.yaml")           // immutable
/// ReloadingFileProvider<FlightYAMLSnapshot>(filePath: "flight.yaml")  // polling
/// ```
///
/// The subset grammar, the `${VAR}` rules, and every "this is outside the
/// subset" error are unchanged — they come from `FlightConfigCore`, the same
/// code the build plugin runs, so build-time and runtime still cannot
/// disagree about what a file says.
///
/// ## Values are string-native
///
/// Flight's parser flattens a document to `[String: String]` — YAML's typing
/// rules are deliberately not applied. A snapshot therefore answers a request
/// for *any* `ConfigType` by converting the raw string, which means Flight's
/// own YAML works with the whole swift-configuration accessor surface —
/// `config.int(forKey:)`, `config.stringArray(forKey:)` — as well as with the
/// `Configuration` facade.
public struct FlightYAMLSnapshot: FileConfigSnapshot {

    /// Parsing knobs. `${VAR}` substitution is the only one Flight has, and
    /// the default — resolve against the process environment — is the correct
    /// runtime behavior; the build plugin passes `.none`.
    public struct ParsingOptions: FileParsingOptions {

        /// How `${VAR}` placeholders are resolved.
        public var substitution: EnvironmentSubstitutionPolicy

        public init(substitution: EnvironmentSubstitutionPolicy = .processEnvironment) {
            self.substitution = substitution
        }

        public static let `default` = ParsingOptions()
    }

    public let providerName: String

    /// The parsed, flattened, substituted document.
    public let document: FlightYAMLDocument

    /// Creates a snapshot from raw file bytes — the `FileConfigSnapshot`
    /// requirement, called by `FileProvider` and `ReloadingFileProvider`.
    ///
    /// Non-UTF-8 input fails as `ConfigLoadError.unreadableFile`; everything
    /// else a file can get wrong (syntax, out-of-subset constructs, unresolved
    /// substitutions, colliding keys) surfaces as the `ConfigLoadError` the
    /// parser already produces.
    public init(data: RawSpan, providerName: String, parsingOptions: ParsingOptions) throws {
        // One bulk copy. This used to load the file a byte at a time through
        // `unsafeLoad(fromByteOffset:as:)` — a loop per byte of every config
        // file, where `withUnsafeBytes` hands over the whole region.
        let text: String? = data.withUnsafeBytes { buffer in
            String(bytes: buffer, encoding: .utf8)
        }
        guard let text else {
            throw ConfigLoadError.unreadableFile(
                path: providerName, reason: "file is not valid UTF-8 text"
            )
        }
        self.providerName = providerName
        self.document = try FlightYAMLDocument(
            string: text, name: providerName, substitution: parsingOptions.substitution
        )
    }

    /// Creates a snapshot from an already-parsed document — the path
    /// `Configuration.load` uses, so the loader can keep reading files
    /// synchronously at bootstrap.
    public init(document: FlightYAMLDocument, providerName: String) {
        self.providerName = providerName
        self.document = document
    }

    public func value(forKey key: AbsoluteConfigKey, type: ConfigType) throws -> LookupResult {
        let encodedKey = key.components.joined(separator: ".")

        // Sequences flatten by index (`hosts.0`, `hosts.1`), so an array
        // request gathers the contiguous run starting at .0. Done before the
        // scalar lookup because the two never collide: the parser rejects a
        // document that defines both `hosts` and `hosts.0`.
        // A value substituted from the environment is where the secrets go —
        // that is what `${DB_PASSWORD}` is for — and every ConfigValue built
        // here was flagged `isSecret: false`. So the redaction config.md
        // promises held only for the provider's own `debugDescription`: a
        // read through `Configuration.reader` with an `AccessLogger` reported
        // the resolved secret as an ordinary value, in the log.
        let isSecret = document.substitutedKeys.contains(encodedKey)

        if type.isArray {
            if let elements = document.arrayElements(for: encodedKey) {
                return LookupResult(
                    encodedKey: encodedKey,
                    value: try ConfigValue(
                        arrayOf: elements, as: type, key: encodedKey,
                        isSecret: isSecret || elements.indices.contains {
                            document.substitutedKeys.contains("\(encodedKey).\($0)")
                        })
                )
            }
        }

        guard let raw = document.rawValue(for: encodedKey) else {
            // Absent *here* — the reader moves on to the next provider.
            return LookupResult(encodedKey: encodedKey, value: nil)
        }
        return LookupResult(
            encodedKey: encodedKey,
            value: try ConfigValue(
                scalar: raw, as: type, key: encodedKey, isSecret: isSecret)
        )
    }

    public var description: String {
        "FlightYAML[\(providerName), \(document.keys.count) keys]"
    }

    public var debugDescription: String {
        description
    }
}

// MARK: - Raw string → ConfigValue

extension ConfigValue {

    /// Converts one raw YAML string into the requested `ConfigType`.
    ///
    /// Conversion failure throws rather than returning nil, matching every
    /// other provider: nil means *absent* and lets the reader fall through to
    /// a lower-precedence layer, which is exactly the silent-wrong-value
    /// outcome this library exists to prevent.
    fileprivate init(
        scalar raw: String, as type: ConfigType, key: String, isSecret: Bool
    ) throws {
        guard let content = ConfigContent.flightScalar(raw, as: type) else {
            throw FlightYAMLConversionError(key: key, rawValue: raw, type: type)
        }
        self = .init(content, isSecret: isSecret)
    }

    /// Converts a flattened sequence (`hosts.0`, `hosts.1`, …) into an array
    /// value of the requested element type.
    fileprivate init(
        arrayOf elements: [String], as type: ConfigType, key: String, isSecret: Bool
    ) throws {
        func mapped<T>(_ transform: (String) -> T?) throws -> [T] {
            try elements.map { element in
                guard let value = transform(element) else {
                    throw FlightYAMLConversionError(key: key, rawValue: element, type: type)
                }
                return value
            }
        }
        switch type {
        case .stringArray:
            self = .init(.stringArray(elements), isSecret: isSecret)
        case .intArray:
            self = .init(.intArray(try mapped { Int(configValue: $0) }), isSecret: isSecret)
        case .doubleArray:
            self = .init(.doubleArray(try mapped { Double(configValue: $0) }), isSecret: isSecret)
        case .boolArray:
            self = .init(.boolArray(try mapped { Bool(configValue: $0) }), isSecret: isSecret)
        case .byteChunkArray:
            self = .init(.byteChunkArray(elements.map { [UInt8]($0.utf8) }), isSecret: isSecret)
        default:
            throw FlightYAMLConversionError(key: key, rawValue: elements.joined(separator: ","), type: type)
        }
    }
}

extension ConfigType {
    fileprivate var isArray: Bool {
        switch self {
        case .stringArray, .intArray, .doubleArray, .boolArray, .byteChunkArray:
            return true
        case .string, .int, .double, .bool, .bytes:
            return false
        }
    }
}

/// A value exists at this key but is not the type the caller asked for.
///
/// The `Configuration` facade catches this and retries the other config types
/// before deciding a value is genuinely undecodable, so this error normally
/// surfaces only to callers using the swift-configuration reader API directly.
struct FlightYAMLConversionError: Error, CustomStringConvertible {
    let key: String
    let rawValue: String
    let type: ConfigType

    var description: String {
        "Configuration key '\(key)' has value '\(rawValue)', which is not a valid \(type.rawValue)."
    }
}
