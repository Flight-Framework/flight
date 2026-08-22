import FlightChannelsClient
import FlightChannelsTesting
import FlightPresenceClient
import FlightPresenceProtocol
import Testing
import struct Foundation.URL
@testable import FlightPresence

/// The Swift client presence helper against the real stack (design §6,
/// Channels §7.2): ChannelClient over the in-process upgrade pipeline,
/// `ChannelPresence` maintaining the list.
@Suite("ChannelPresence — Swift client helper (§6)", .timeLimit(.minutes(1)))
struct ClientHelperTests {

    @Test("state then diffs maintain the list; changes stream reports net effects")
    func endToEnd() async throws {
        let node = try PresenceNode(name: "solo")
        defer { Task { await node.shutdown() } }

        let transport = InMemoryChannelTransport(testClient: node.client, query: "user=carol")
        let client = ChannelClient(url: URL(string: "flight-test:///socket")!, transport: transport)
        try await client.connect()
        defer { Task { await client.disconnect() } }

        let room = client.channel("room:1")
        let presence = ChannelPresence(channel: room)
        await presence.start()
        let changes = await presence.changes()
        var iterator = changes.makeAsyncIterator()

        try await room.join()

        // Initial state: carol herself.
        let initial = await iterator.next()
        #expect(initial?.list.map(\.key) == ["carol"])
        #expect(initial?.joins["carol"]?.count == 1)

        // A second member arrives on the wire side.
        let dave = try await node.wire(user: "dave")
        try await dave.join("room:1")
        let joined = await iterator.next()
        #expect(joined?.list.map(\.key) == ["carol", "dave"])
        #expect(joined?.joins.keys.sorted() == ["dave"])
        #expect(joined?.leaves.isEmpty == true)

        // Dave updates his status: normalized — a join, never a flap.
        try dave.send(ref: "s1", topic: "room:1", event: "status", payload: .object(["status": .string("away")]))
        let updated = await iterator.next()
        #expect(updated?.leaves.isEmpty == true)
        #expect(updated?.joins["dave"]?.first?.payload == ["status": "away"])
        #expect(updated?.list.count == 2)

        // Dave disconnects: a genuine leave.
        dave.close()
        let left = await iterator.next()
        #expect(left?.leaves.keys.sorted() == ["dave"])
        #expect(left?.list.map(\.key) == ["carol"])

        let current = await presence.list
        #expect(current.map(\.key) == ["carol"])
    }
}
