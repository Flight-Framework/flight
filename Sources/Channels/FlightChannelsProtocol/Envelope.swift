import struct Foundation.Data
import class Foundation.JSONDecoder
import class Foundation.JSONEncoder

/// The one wire shape: client → server and server → client share this
/// envelope. JSON text frames in v1; the payload stays opaque to the framing
/// layer the same way PubSub's does.
///
///     { "ref": "7", "topic": "room:42", "event": "new_msg", "payload": {…} }
///
/// `ref` correlates a request with its reply; server-initiated pushes
/// carry `ref: null`. All four keys are always present on the wire —
/// "one well-designed shape", no optional-field dialects.
public struct Envelope: Sendable, Equatable {
    /// Client-generated message ref for reply correlation; nil on server
    /// pushes (encoded as an explicit JSON `null`).
    public var ref: String?
    public var topic: String
    /// Reserved lifecycle events are namespaced `flight:`; everything
    /// else is an application event.
    public var event: String
    /// Opaque to the framing layer.
    public var payload: JSONValue

    public init(ref: String?, topic: String, event: String, payload: JSONValue = .object([:])) {
        self.ref = ref
        self.topic = topic
        self.event = event
        self.payload = payload
    }
}

// MARK: - Codable (explicit, to pin the wire contract)

extension Envelope: Codable {
    private enum CodingKeys: String, CodingKey {
        case ref, topic, event, payload
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Tolerant on the way in (an absent ref reads as null; an absent
        // payload reads as {}), strict on the way out — classic robustness
        // principle, applied within one owned protocol.
        self.ref = try container.decodeIfPresent(String.self, forKey: .ref)
        self.topic = try container.decode(String.self, forKey: .topic)
        self.event = try container.decode(String.self, forKey: .event)
        self.payload = try container.decodeIfPresent(JSONValue.self, forKey: .payload) ?? .object([:])
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let ref {
            try container.encode(ref, forKey: .ref)
        } else {
            try container.encodeNil(forKey: .ref)
        }
        try container.encode(topic, forKey: .topic)
        try container.encode(event, forKey: .event)
        try container.encode(payload, forKey: .payload)
    }
}

// MARK: - Text-frame codec

/// A malformed inbound frame. Because Flight owns both clients, a frame
/// that doesn't decode is a bug or an attack, never a compatibility case —
/// the server responds by closing the socket (`CloseCode.protocolViolation`).
public struct EnvelopeDecodingError: Error, Sendable, CustomStringConvertible {
    public let detail: String
    public init(_ detail: String) { self.detail = detail }
    public var description: String { "Malformed envelope: \(detail)" }
}

/// The two coders every frame goes through.
///
/// One each, not one per frame. `JSONEncoder`/`JSONDecoder` are classes with
/// real setup cost, and a fresh pair was allocated for every frame decoded,
/// every frame encoded, and twice more per broadcast — on the hottest path
/// in the product. Both are stateless in use and safe to share; the encoder's
/// configuration is fixed here so it cannot drift between call sites, which
/// matters because the wire form is a pinned contract.
public enum WireCoders {
    /// Sorted keys so the wire form is deterministic — protocol tests (Swift
    /// and JS both) assert on exact frames, and support debugging shouldn't
    /// fight key order.
    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    public static let decoder = JSONDecoder()
}

extension Envelope {
    /// Decodes one text frame.
    public init(text: String) throws {
        do {
            self = try WireCoders.decoder.decode(Envelope.self, from: Data(text.utf8))
        } catch {
            throw EnvelopeDecodingError(String(describing: error))
        }
    }

    /// Encodes to one text frame.
    public func encodedText() throws -> String {
        String(decoding: try WireCoders.encoder.encode(self), as: UTF8.self)
    }
}
