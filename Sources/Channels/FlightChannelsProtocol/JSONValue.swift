/// An arbitrary JSON value — the representation of the envelope's opaque
/// `payload`.
///
/// The framing layer moves payloads without interpreting them, but it still
/// has to *hold* them in a `Sendable`, `Codable` shape between the wire and
/// the handler. `JSONValue` is that shape: the full JSON data model, nothing
/// more. Handlers that want typed payloads decode them (`payload.decode()`);
/// handlers that just route can pass the value straight through.
///
/// Numbers are `Double`, deliberately: the protocol's primary peer is a
/// JavaScript client, whose numbers are IEEE 754 doubles. Exact
/// integers up to 2⁵³ round-trip losslessly; `intValue` refuses anything
/// that doesn't.
public enum JSONValue: Sendable, Equatable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

// MARK: - Codable

extension JSONValue: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Value is not representable as JSON."
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

// MARK: - Literals

extension JSONValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}

extension JSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
}

extension JSONValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .number(value) }
}

extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension JSONValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

// MARK: - Accessors

extension JSONValue {
    public var isNull: Bool { self == .null }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var doubleValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    /// The number as an `Int`, only when the conversion is exact.
    public var intValue: Int? {
        guard case .number(let value) = self else { return nil }
        guard let exact = Int(exactly: value) else { return nil }
        return exact
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    /// Object member lookup; `.null`-safe (`payload["a"]["b"]` never traps,
    /// it just yields nil once the path leaves the object tree).
    public subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    public subscript(index: Int) -> JSONValue? {
        guard case .array(let values) = self, values.indices.contains(index) else { return nil }
        return values[index]
    }
}

// MARK: - Typed bridging

import struct Foundation.Data
import class Foundation.JSONEncoder
import class Foundation.JSONDecoder

extension JSONValue {
    /// Re-encodes this value and decodes it as `T` — how a handler lifts an
    /// opaque payload into its own typed message struct.
    public func decode<T: Decodable>(_ type: T.Type = T.self) throws -> T {
        let data = try WireCoders.encoder.encode(self)
        return try WireCoders.decoder.decode(type, from: data)
    }

    /// Encodes any `Encodable` into a `JSONValue` — how typed application
    /// messages become payloads.
    public init(encoding value: some Encodable) throws {
        let data = try WireCoders.encoder.encode(value)
        self = try WireCoders.decoder.decode(JSONValue.self, from: data)
    }
}
