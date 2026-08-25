import Foundation
import Testing
import FlightPubSub

@Suite("Message")
struct MessageTests {

    @Test("metadata defaults to empty")
    func metadataDefault() {
        let message = Message(topic: "room:42", payload: Data([0x01]))
        #expect(message.metadata.isEmpty)
        #expect(message.topic == "room:42")
        #expect(message.payload == Data([0x01]))
    }

    @Test("equatable over all three fields")
    func equatable() {
        let a = msg("t", "hello", metadata: ["k": "v"])
        let b = msg("t", "hello", metadata: ["k": "v"])
        #expect(a == b)
        #expect(a != msg("t", "hello"))
        #expect(a != msg("other", "hello", metadata: ["k": "v"]))
        #expect(a != msg("t", "bye", metadata: ["k": "v"]))
    }

    @Test("payload is opaque binary — arbitrary bytes survive")
    func binaryPayload() {
        let bytes = Data((0...255).map { UInt8($0) })
        let message = Message(topic: "bin", payload: bytes)
        #expect(message.payload == bytes)
    }

    @Test("topic strings are opaque — empty and unicode topics are legal")
    func opaqueTopics() async {
        let pubsub = LocalPubSub()
        for topic in ["", "room:*:weird", "émoji-🚀", "a b c"] {
            var iterator = pubsub.subscribe(topic).makeAsyncIterator()
            await pubsub.publish(msg(topic, "x"))
            let received = await iterator.next()
            #expect(received?.topic == topic)
        }
    }

    @Test("codable round-trip for adapter wire use")
    func codableRoundTrip() throws {
        let original = msg("room:42", "payload", metadata: ["origin": "n1", "k": "v"])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Message.self, from: data)
        #expect(decoded == original)
    }
}
