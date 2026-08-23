import JWTKit

/// A JSON value as it appears in a JWT payload. Internal: the public
/// surface is `Principal.claims: [String: any Sendable]`.
enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "unsupported JSON value"
            )
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    /// Bridges to the standard Sendable JSON types for `Principal.claims`.
    /// JSON `null` bridges to `nil` (the claim is dropped).
    var anySendable: (any Sendable)? {
        switch self {
        case .string(let value): value
        case .int(let value): value
        case .double(let value): value
        case .bool(let value): value
        case .array(let value): value.compactMap(\.anySendable)
        case .object(let value): value.compactMapValues(\.anySendable)
        case .null: nil
        }
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    /// JWT NumericDate: seconds since epoch, integer or fractional.
    var numericDateValue: Double? {
        switch self {
        case .int(let value): Double(value)
        case .double(let value): value
        default: nil
        }
    }
}

/// The decoded JWT payload, claims kept verbatim. Signature verification is
/// JWTKit's; claim *policy* is applied by
/// ``OIDCTokenValidator`` after verification, so `verify(using:)` is a
/// deliberate no-op (it lets the validator use an injectable clock and
/// produce precise ``TokenValidationError``s).
struct RawClaims: JWTPayload {
    let values: [String: JSONValue]

    init(values: [String: JSONValue]) {
        self.values = values
    }

    init(from decoder: any Decoder) throws {
        values = try decoder.singleValueContainer().decode([String: JSONValue].self)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(values)
    }

    func verify(using _: some JWTAlgorithm) async throws {
        // Claim policy is enforced by OIDCTokenValidator.
    }

    /// Looks up a claim by name. An exact top-level match wins (Auth0-style
    /// namespaced claims like `https://example.com/roles` contain dots);
    /// otherwise the name is treated as a dot-path into nested objects
    /// (Keycloak-style `realm_access.roles`).
    func value(at path: String) -> JSONValue? {
        if let exact = values[path] { return exact }
        var current: JSONValue = .object(values)
        for component in path.split(separator: ".") {
            guard case .object(let object) = current,
                let next = object[String(component)]
            else { return nil }
            current = next
        }
        if case .object(let object) = current, object == values { return nil }
        return current
    }
}

extension RawClaims {
    /// Union of the values found at `paths`, where each value may be an
    /// array of strings (Keycloak, Okta, Cognito groups) or a single string.
    func stringSet(atAnyOf paths: [String], splittingStringsOn separator: Character? = nil) -> Set<String> {
        var result: Set<String> = []
        for path in paths {
            switch value(at: path) {
            case .array(let items):
                for item in items {
                    if let string = item.stringValue { result.insert(string) }
                }
            case .string(let string):
                if let separator {
                    result.formUnion(
                        string.split(separator: separator).map(String.init)
                    )
                } else {
                    result.insert(string)
                }
            default:
                continue
            }
        }
        result.remove("")
        return result
    }
}
