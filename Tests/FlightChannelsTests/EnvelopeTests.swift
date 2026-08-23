import FlightChannelsProtocol
import Foundation
import Testing

@Suite("Wire protocol — envelope")
struct EnvelopeTests {

    @Test("one envelope shape, exact wire form, all four keys always present")
    func wireShape() throws {
        let envelope = Envelope(
            ref: "7",
            topic: "room:42",
            event: "new_msg",
            payload: ["body": "hi"]
        )
        #expect(try envelope.encodedText()
            == #"{"event":"new_msg","payload":{"body":"hi"},"ref":"7","topic":"room:42"}"#)
    }

    @Test("server pushes carry an explicit ref: null")
    func nullRef() throws {
        let push = Envelope(ref: nil, topic: "room:42", event: "new_msg", payload: .object([:]))
        #expect(try push.encodedText()
            == #"{"event":"new_msg","payload":{},"ref":null,"topic":"room:42"}"#)
    }

    @Test("round-trips through the text codec")
    func roundTrip() throws {
        let original = Envelope(
            ref: "12",
            topic: "game:7",
            event: "move",
            payload: ["x": 3, "y": 4.5, "ok": true, "who": nil, "tags": ["a", "b"]]
        )
        let decoded = try Envelope(text: try original.encodedText())
        #expect(decoded == original)
    }

    @Test("decoding tolerates absent ref and absent payload")
    func tolerantDecoding() throws {
        let decoded = try Envelope(text: #"{"topic":"t","event":"e"}"#)
        #expect(decoded.ref == nil)
        #expect(decoded.payload == .object([:]))
    }

    @Test("missing topic or event is a protocol violation, not a default")
    func strictDecoding() {
        #expect(throws: EnvelopeDecodingError.self) {
            try Envelope(text: #"{"event":"e","payload":{}}"#)
        }
        #expect(throws: EnvelopeDecodingError.self) {
            try Envelope(text: #"{"topic":"t","payload":{}}"#)
        }
        #expect(throws: EnvelopeDecodingError.self) {
            try Envelope(text: "not json at all")
        }
    }

    @Test("payload is opaque: arbitrary nesting survives untouched")
    func opaquePayload() throws {
        let payload: JSONValue = [
            "diff": [["op": "replace", "path": "/2/text", "value": "hello"]],
            "meta": ["depth": 3, "flags": [true, false, nil]],
        ]
        let decoded = try Envelope(
            text: try Envelope(ref: nil, topic: "live:1", event: "diff", payload: payload).encodedText()
        )
        #expect(decoded.payload == payload)
    }

    @Test("reserved events are exactly the flight: set")
    func reservedEvents() {
        #expect(ReservedEvent.allCases.map(\.rawValue).sorted() == [
            "flight:close", "flight:error", "flight:heartbeat",
            "flight:join", "flight:leave", "flight:reply",
        ])
        #expect(ReservedEvent(rawValue: "new_msg") == nil)
        #expect(ReservedEvent(rawValue: "flight:join") == .join)
    }
}

@Suite("Wire protocol — JSONValue")
struct JSONValueTests {

    @Test("literals build the value you'd write by hand")
    func literals() {
        let value: JSONValue = [
            "string": "s", "int": 3, "double": 1.5, "bool": true,
            "null": nil, "array": [1, 2], "object": ["k": "v"],
        ]
        #expect(value["string"] == .string("s"))
        #expect(value["int"]?.intValue == 3)
        #expect(value["double"]?.doubleValue == 1.5)
        #expect(value["bool"]?.boolValue == true)
        #expect(value["null"]?.isNull == true)
        #expect(value["array"]?[1] == .number(2))
        #expect(value["object"]?["k"] == .string("v"))
        #expect(value["absent"] == nil)
    }

    @Test("intValue only for exact integers")
    func intExactness() {
        #expect(JSONValue.number(42).intValue == 42)
        #expect(JSONValue.number(42.5).intValue == nil)
        #expect(JSONValue.string("42").intValue == nil)
    }

    @Test("typed bridging: Encodable in, Decodable out")
    func typedBridging() throws {
        struct Move: Codable, Equatable {
            let x: Int
            let y: Int
            let label: String?
        }
        let move = Move(x: 1, y: 2, label: nil)
        let payload = try JSONValue(encoding: move)
        #expect(payload["x"]?.intValue == 1)
        #expect(try payload.decode(Move.self) == move)
    }

    @Test("out-of-range subscripts are nil, never a trap")
    func safeSubscripts() {
        let value: JSONValue = ["a": [1]]
        #expect(value["a"]?[5] == nil)
        #expect(value[0] == nil)
        #expect(JSONValue.null["k"] == nil)
    }
}
