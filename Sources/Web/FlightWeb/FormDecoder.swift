import Foundation

/// Decodes `application/x-www-form-urlencoded` bodies into `Decodable`
/// types — what an HTML `<form method="post">` (and every OAuth token
/// endpoint) actually sends.
///
/// The wire semantics, decided rather than inherited, because the format
/// has no single spec for the edges:
///
/// - Pairs split on `&` only. `;` is ordinary value text (the W3C spec
///   dropped it as a separator).
/// - `+` means space in names and values; a literal plus arrives as `%2B`.
/// - Percent-escapes are decoded strictly: `%G1` or a truncated `%2` is a
///   decoding error, never silently passed through. Decoded bytes must be
///   valid UTF-8.
/// - A key repeated with a scalar target: the **last** occurrence wins
///   (HTML's "later field overrides"). With an array target (`[String]`,
///   `[Int]`…): every occurrence, in order.
/// - `a=` (and a bare `a`) is the empty string — present, not nil. Only an
///   *absent* key is nil for optionals; `Int?` receiving `a=` is a type
///   mismatch, deliberately, because silently reading garbage as nil hides
///   bugs.
/// - `Bool` accepts `true`/`false`/`1`/`0`/`on`/`off`, case-insensitively —
///   and, the one deliberate deviation from `JSONDecoder` strictness: a
///   **non-optional `Bool` whose key is absent decodes as `false`**,
///   because an unchecked HTML checkbox sends nothing at all. `Bool?` opts
///   out (absent → nil).
/// - Bodies are flat. Nested containers (`a[b]=c` bracket syntax) are
///   refused with an error that says so: the nesting semantics are
///   folklore that every framework hand-rolls differently, and guessing
///   wrong is worse than refusing.
/// - `Date` and `Data` targets are refused with a message naming the fix
///   (model them as `String` and convert) rather than failing on a numeric
///   parse three layers down.
///
/// Errors are thrown as `DecodingError`, so a failed decode renders to the
/// client through the same path-and-reason machinery JSON bodies get.
public struct FormDecoder: Sendable {
    public init() {}

    public func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let pairs = try FormParser.parse(data)
        var values: [String: [String]] = [:]
        for (name, value) in pairs {
            values[name, default: []].append(value)
        }
        return try T(from: _FormDecoder(values: values, codingPath: []))
    }
}

// MARK: - The wire parser

enum FormParser {
    /// Splits and decodes the raw body into ordered pairs. Splitting
    /// happens **before** percent-decoding — an encoded `%26` is data, not
    /// a separator — and decoding is strict both about escapes and UTF-8.
    static func parse(_ data: Data) throws -> [(name: String, value: String)] {
        var pairs: [(String, String)] = []
        for segment in data.split(separator: UInt8(ascii: "&"), omittingEmptySubsequences: true) {
            let name: Data.SubSequence
            let value: Data.SubSequence
            if let equals = segment.firstIndex(of: UInt8(ascii: "=")) {
                name = segment[..<equals]
                value = segment[segment.index(after: equals)...]
            } else {
                name = segment
                value = segment[segment.endIndex...]
            }
            pairs.append((try decodeComponent(name), try decodeComponent(value)))
        }
        return pairs
    }

    private static func decodeComponent(_ bytes: Data.SubSequence) throws -> String {
        var decoded = Data(capacity: bytes.count)
        var index = bytes.startIndex
        while index < bytes.endIndex {
            let byte = bytes[index]
            switch byte {
            case UInt8(ascii: "+"):
                decoded.append(UInt8(ascii: " "))
                index = bytes.index(after: index)
            case UInt8(ascii: "%"):
                let first = bytes.index(after: index)
                guard first < bytes.endIndex, let high = hexValue(bytes[first]),
                    case let second = bytes.index(after: first), second < bytes.endIndex,
                    let low = hexValue(bytes[second])
                else {
                    throw DecodingError.dataCorrupted(
                        DecodingError.Context(
                            codingPath: [],
                            debugDescription: "invalid percent escape in form body"))
                }
                decoded.append(high << 4 | low)
                index = bytes.index(after: second)
            default:
                decoded.append(byte)
                index = bytes.index(after: index)
            }
        }
        guard let text = String(data: decoded, encoding: .utf8) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: [],
                    debugDescription: "form body is not valid UTF-8"))
        }
        return text
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return byte - UInt8(ascii: "A") + 10
        default: return nil
        }
    }
}

// MARK: - Decoder plumbing

private struct _FormDecoder: Decoder {
    let values: [String: [String]]
    let codingPath: [any CodingKey]
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        KeyedDecodingContainer(_KeyedContainer<Key>(values: values, codingPath: codingPath))
    }

    func unkeyedContainer() throws -> any UnkeyedDecodingContainer {
        throw DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "form bodies decode into keyed types, not top-level arrays"))
    }

    func singleValueContainer() throws -> any SingleValueDecodingContainer {
        throw DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "form bodies decode into keyed types, not single values"))
    }
}

private struct _KeyedContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let values: [String: [String]]
    let codingPath: [any CodingKey]

    var allKeys: [Key] { values.keys.compactMap { Key(stringValue: $0) } }

    func contains(_ key: Key) -> Bool { values[key.stringValue] != nil }

    func decodeNil(forKey key: Key) throws -> Bool {
        // Absent is nil; a present-but-empty value (`a=`) is "", not nil.
        values[key.stringValue] == nil
    }

    /// The last occurrence — scalars take HTML's "later field overrides".
    private func scalar(_ key: Key) throws -> String {
        guard let last = values[key.stringValue]?.last else {
            throw DecodingError.keyNotFound(
                key,
                DecodingError.Context(
                    codingPath: codingPath,
                    debugDescription: "no form field named '\(key.stringValue)'"))
        }
        return last
    }

    func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool {
        // The checkbox rule: an unchecked checkbox sends nothing at all, so
        // absent decodes as false rather than throwing. `Bool?` opts out.
        guard values[key.stringValue] != nil else { return false }
        return try FormScalar.bool(try scalar(key), path: codingPath + [key])
    }

    func decode(_ type: String.Type, forKey key: Key) throws -> String {
        try scalar(key)
    }

    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
        try FormScalar.refuseUnrepresentable(type, path: codingPath + [key])
        if type == URL.self {
            return try FormScalar.url(try scalar(key), path: codingPath + [key]) as! T
        }
        guard let all = values[key.stringValue], !all.isEmpty else {
            throw DecodingError.keyNotFound(
                key,
                DecodingError.Context(
                    codingPath: codingPath,
                    debugDescription: "no form field named '\(key.stringValue)'"))
        }
        return try T(from: _ValueDecoder(values: all, codingPath: codingPath + [key]))
    }

    func nestedContainer<NestedKey: CodingKey>(
        keyedBy type: NestedKey.Type, forKey key: Key
    ) throws -> KeyedDecodingContainer<NestedKey> {
        throw FormScalar.flatOnly(path: codingPath + [key])
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> any UnkeyedDecodingContainer {
        throw FormScalar.flatOnly(path: codingPath + [key])
    }

    func superDecoder() throws -> any Decoder { throw FormScalar.flatOnly(path: codingPath) }
    func superDecoder(forKey key: Key) throws -> any Decoder {
        throw FormScalar.flatOnly(path: codingPath + [key])
    }
}

/// Decodes the value(s) of one form field: a single value when asked as a
/// scalar (last occurrence already selected by the keyed container), every
/// occurrence when asked as an array.
private struct _ValueDecoder: Decoder {
    let values: [String]
    let codingPath: [any CodingKey]
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        throw FormScalar.flatOnly(path: codingPath)
    }

    func unkeyedContainer() throws -> any UnkeyedDecodingContainer {
        _UnkeyedValues(values: values, codingPath: codingPath)
    }

    func singleValueContainer() throws -> any SingleValueDecodingContainer {
        _SingleValue(value: values.last ?? "", codingPath: codingPath)
    }
}

private struct _UnkeyedValues: UnkeyedDecodingContainer {
    let values: [String]
    let codingPath: [any CodingKey]
    var currentIndex = 0

    var count: Int? { values.count }
    var isAtEnd: Bool { currentIndex >= values.count }

    private mutating func next() throws -> String {
        guard !isAtEnd else {
            throw DecodingError.valueNotFound(
                String.self,
                DecodingError.Context(
                    codingPath: codingPath,
                    debugDescription: "no more values (\(values.count) total)"))
        }
        defer { currentIndex += 1 }
        return values[currentIndex]
    }

    mutating func decodeNil() throws -> Bool { false }
    mutating func decode(_ type: String.Type) throws -> String { try next() }
    mutating func decode(_ type: Bool.Type) throws -> Bool {
        try FormScalar.bool(try next(), path: codingPath)
    }

    mutating func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try FormScalar.refuseUnrepresentable(type, path: codingPath)
        if type == URL.self {
            return try FormScalar.url(try next(), path: codingPath) as! T
        }
        return try T(from: _ValueDecoder(values: [try next()], codingPath: codingPath))
    }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy type: NestedKey.Type
    ) throws -> KeyedDecodingContainer<NestedKey> {
        throw FormScalar.flatOnly(path: codingPath)
    }

    mutating func nestedUnkeyedContainer() throws -> any UnkeyedDecodingContainer {
        throw FormScalar.flatOnly(path: codingPath)
    }

    mutating func superDecoder() throws -> any Decoder {
        throw FormScalar.flatOnly(path: codingPath)
    }
}

private struct _SingleValue: SingleValueDecodingContainer {
    let value: String
    let codingPath: [any CodingKey]

    func decodeNil() -> Bool { false }  // a present value is never nil, "" included
    func decode(_ type: String.Type) throws -> String { value }
    func decode(_ type: Bool.Type) throws -> Bool {
        try FormScalar.bool(value, path: codingPath)
    }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try FormScalar.refuseUnrepresentable(type, path: codingPath)
        if type == URL.self {
            return try FormScalar.url(value, path: codingPath) as! T
        }
        return try T(from: _ValueDecoder(values: [value], codingPath: codingPath))
    }
}

// MARK: - Shared scalar parsing

/// One home for the text → value rules, plus LosslessStringConvertible
/// routing so every numeric type shares one code path and one error shape.
private enum FormScalar {
    static func bool(_ text: String, path: [any CodingKey]) throws -> Bool {
        switch text.lowercased() {
        case "true", "1", "on": return true
        case "false", "0", "off": return false
        default:
            throw DecodingError.typeMismatch(
                Bool.self,
                DecodingError.Context(
                    codingPath: path,
                    debugDescription:
                        "'\(text)' is not a form boolean (true/false/1/0/on/off)"))
        }
    }

    static func number<N: LosslessStringConvertible>(
        _ type: N.Type, _ text: String, path: [any CodingKey]
    ) throws -> N {
        guard let parsed = N(text) else {
            throw DecodingError.typeMismatch(
                type,
                DecodingError.Context(
                    codingPath: path,
                    debugDescription: "'\(text)' is not a valid \(type)"))
        }
        return parsed
    }

    /// `URL` is special-cased the way `JSONDecoder` special-cases it: its
    /// own `Decodable` uses a keyed container on Linux Foundation, which a
    /// flat form cannot satisfy — while "a URL in a form field" is entirely
    /// ordinary.
    static func url(_ text: String, path: [any CodingKey]) throws -> URL {
        guard let url = URL(string: text), !text.isEmpty else {
            throw DecodingError.typeMismatch(
                URL.self,
                DecodingError.Context(
                    codingPath: path,
                    debugDescription: "'\(text)' is not a valid URL"))
        }
        return url
    }

    static func refuseUnrepresentable<T>(_ type: T.Type, path: [any CodingKey]) throws {
        if type == Date.self {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: path,
                    debugDescription:
                        "form bodies have no Date representation — model the field as String and parse it in your initializer"
                ))
        }
        if type == Data.self {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: path,
                    debugDescription:
                        "form bodies have no binary representation — file content belongs in multipart/form-data"
                ))
        }
    }

    static func flatOnly(path: [any CodingKey]) -> DecodingError {
        .dataCorrupted(
            DecodingError.Context(
                codingPath: path,
                debugDescription:
                    "form bodies are flat — bracket nesting (a[b]=c) has no standard semantics and is not supported"
            ))
    }
}

// The numeric requirements, all routed through FormScalar.number. Written
// out because the protocols require concrete witnesses; the logic lives in
// exactly one place above.
extension _KeyedContainer {
    func decode(_ type: Double.Type, forKey key: Key) throws -> Double {
        try FormScalar.number(type, try scalarForNumber(key), path: codingPath + [key])
    }
    func decode(_ type: Float.Type, forKey key: Key) throws -> Float {
        try FormScalar.number(type, try scalarForNumber(key), path: codingPath + [key])
    }
    func decode(_ type: Int.Type, forKey key: Key) throws -> Int {
        try FormScalar.number(type, try scalarForNumber(key), path: codingPath + [key])
    }
    func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 {
        try FormScalar.number(type, try scalarForNumber(key), path: codingPath + [key])
    }
    func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 {
        try FormScalar.number(type, try scalarForNumber(key), path: codingPath + [key])
    }
    func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 {
        try FormScalar.number(type, try scalarForNumber(key), path: codingPath + [key])
    }
    func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 {
        try FormScalar.number(type, try scalarForNumber(key), path: codingPath + [key])
    }
    func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt {
        try FormScalar.number(type, try scalarForNumber(key), path: codingPath + [key])
    }
    func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 {
        try FormScalar.number(type, try scalarForNumber(key), path: codingPath + [key])
    }
    func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 {
        try FormScalar.number(type, try scalarForNumber(key), path: codingPath + [key])
    }
    func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 {
        try FormScalar.number(type, try scalarForNumber(key), path: codingPath + [key])
    }
    func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 {
        try FormScalar.number(type, try scalarForNumber(key), path: codingPath + [key])
    }

    private func scalarForNumber(_ key: Key) throws -> String { try scalar(key) }
}

extension _UnkeyedValues {
    mutating func decode(_ type: Double.Type) throws -> Double {
        try FormScalar.number(type, try nextForNumber(), path: codingPath)
    }
    mutating func decode(_ type: Float.Type) throws -> Float {
        try FormScalar.number(type, try nextForNumber(), path: codingPath)
    }
    mutating func decode(_ type: Int.Type) throws -> Int {
        try FormScalar.number(type, try nextForNumber(), path: codingPath)
    }
    mutating func decode(_ type: Int8.Type) throws -> Int8 {
        try FormScalar.number(type, try nextForNumber(), path: codingPath)
    }
    mutating func decode(_ type: Int16.Type) throws -> Int16 {
        try FormScalar.number(type, try nextForNumber(), path: codingPath)
    }
    mutating func decode(_ type: Int32.Type) throws -> Int32 {
        try FormScalar.number(type, try nextForNumber(), path: codingPath)
    }
    mutating func decode(_ type: Int64.Type) throws -> Int64 {
        try FormScalar.number(type, try nextForNumber(), path: codingPath)
    }
    mutating func decode(_ type: UInt.Type) throws -> UInt {
        try FormScalar.number(type, try nextForNumber(), path: codingPath)
    }
    mutating func decode(_ type: UInt8.Type) throws -> UInt8 {
        try FormScalar.number(type, try nextForNumber(), path: codingPath)
    }
    mutating func decode(_ type: UInt16.Type) throws -> UInt16 {
        try FormScalar.number(type, try nextForNumber(), path: codingPath)
    }
    mutating func decode(_ type: UInt32.Type) throws -> UInt32 {
        try FormScalar.number(type, try nextForNumber(), path: codingPath)
    }
    mutating func decode(_ type: UInt64.Type) throws -> UInt64 {
        try FormScalar.number(type, try nextForNumber(), path: codingPath)
    }

    private mutating func nextForNumber() throws -> String { try next() }
}

extension _SingleValue {
    func decode(_ type: Double.Type) throws -> Double {
        try FormScalar.number(type, value, path: codingPath)
    }
    func decode(_ type: Float.Type) throws -> Float {
        try FormScalar.number(type, value, path: codingPath)
    }
    func decode(_ type: Int.Type) throws -> Int {
        try FormScalar.number(type, value, path: codingPath)
    }
    func decode(_ type: Int8.Type) throws -> Int8 {
        try FormScalar.number(type, value, path: codingPath)
    }
    func decode(_ type: Int16.Type) throws -> Int16 {
        try FormScalar.number(type, value, path: codingPath)
    }
    func decode(_ type: Int32.Type) throws -> Int32 {
        try FormScalar.number(type, value, path: codingPath)
    }
    func decode(_ type: Int64.Type) throws -> Int64 {
        try FormScalar.number(type, value, path: codingPath)
    }
    func decode(_ type: UInt.Type) throws -> UInt {
        try FormScalar.number(type, value, path: codingPath)
    }
    func decode(_ type: UInt8.Type) throws -> UInt8 {
        try FormScalar.number(type, value, path: codingPath)
    }
    func decode(_ type: UInt16.Type) throws -> UInt16 {
        try FormScalar.number(type, value, path: codingPath)
    }
    func decode(_ type: UInt32.Type) throws -> UInt32 {
        try FormScalar.number(type, value, path: codingPath)
    }
    func decode(_ type: UInt64.Type) throws -> UInt64 {
        try FormScalar.number(type, value, path: codingPath)
    }
}
