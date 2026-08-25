import FlightChannelsClient
import FlightChannelsTesting
import Foundation
import Testing

@Suite("Swift client — join, push, replies", .timeLimit(.minutes(1)))
struct ChannelClientTests {

    @Test("connect, join, awaited push, disconnect — the happy path")
    func happyPath() async throws {
        let harness = try ClientHarness()
        let client = harness.makeClient()
        try await client.connect()
        #expect(await client.connectionState == .connected)

        let counter = client.channel("counter:1")
        let initialState = try await counter.join()
        #expect(initialState == ["count": 0])
        #expect(await client.isJoined("counter:1"))

        let reply = try await counter.push("echo", payload: ["value": 41])
        #expect(reply == ["value": 41])

        await client.disconnect()
        #expect(await client.connectionState == .closed)
    }

    @Test("join rejection throws channelError with the wire reason")
    func joinRejected() async throws {
        let harness = try ClientHarness()
        let client = harness.makeClient()
        try await client.connect()

        await #expect(throws: ChannelClientError.channelError(reason: "forbidden")) {
            try await client.channel("counter:locked").join()
        }
        #expect(await !client.isJoined("counter:locked"))
        await client.disconnect()
    }

    @Test("handler error rejects the awaited push")
    func handlerError() async throws {
        let harness = try ClientHarness()
        let client = harness.makeClient()
        try await client.connect()
        let counter = client.channel("counter:1")
        try await counter.join()

        await #expect(throws: ChannelClientError.channelError(reason: "nope")) {
            try await counter.push("fail")
        }
        await client.disconnect()
    }

    @Test("a handler that never replies times the push out")
    func pushTimeout() async throws {
        let harness = try ClientHarness()
        let client = harness.makeClient(
            configuration: ChannelClientConfiguration(pushTimeout: .milliseconds(100))
        )
        try await client.connect()
        let counter = client.channel("counter:1")
        try await counter.join()

        await #expect(throws: ChannelClientError.timedOut) {
            try await counter.push("silent")
        }
        await client.disconnect()
    }

    @Test("pushing without connecting is notConnected, not a hang")
    func notConnected() async throws {
        let harness = try ClientHarness()
        let client = harness.makeClient()
        await #expect(throws: ChannelClientError.notConnected) {
            try await client.channel("counter:1").push("echo")
        }
    }

    @Test("server pushes arrive on the channel's message stream")
    func messageStream() async throws {
        let harness = try ClientHarness()
        let sender = harness.makeClient()
        let receiver = harness.makeClient()
        try await sender.connect()
        try await receiver.connect()

        let sendingChannel = sender.channel("counter:9")
        let receivingChannel = receiver.channel("counter:9")
        try await sendingChannel.join()
        try await receivingChannel.join()
        let messages = await receivingChannel.messages()

        _ = try await sendingChannel.push("announce", payload: ["n": 1])

        var iterator = messages.makeAsyncIterator()
        let message = await iterator.next()
        #expect(message == ChannelMessage(event: "announced", payload: ["n": 1]))

        await sender.disconnect()
        await receiver.disconnect()
    }

    @Test("fire-and-forget send: no reply awaited, effect still lands")
    func sendWithoutReply() async throws {
        let harness = try ClientHarness()
        let client = harness.makeClient()
        try await client.connect()
        let counter = client.channel("counter:2")
        try await counter.join()
        let messages = await counter.messages()

        try await counter.send("announce_quietly", payload: ["quiet": true])

        var iterator = messages.makeAsyncIterator()
        let message = await iterator.next()
        #expect(message == ChannelMessage(event: "announced", payload: ["quiet": true]))
        await client.disconnect()
    }

    @Test("refs are per-message: interleaved pushes resolve to their own replies")
    func refCorrelation() async throws {
        let harness = try ClientHarness()
        let client = harness.makeClient()
        try await client.connect()
        let counter = client.channel("counter:1")
        try await counter.join()

        // Concurrent pushes; each must get exactly its own echo back.
        try await withThrowingTaskGroup(of: (Int, JSONValue).self) { group in
            for n in 0..<20 {
                group.addTask {
                    (n, try await counter.push("echo", payload: ["n": .number(Double(n))]))
                }
            }
            for try await (n, reply) in group {
                #expect(reply == ["n": .number(Double(n))])
            }
        }
        await client.disconnect()
    }

    @Test("leave stops delivery and clears membership")
    func leave() async throws {
        let harness = try ClientHarness()
        let client = harness.makeClient()
        try await client.connect()
        let counter = client.channel("counter:3")
        try await counter.join()
        try await counter.leave()
        #expect(await !client.isJoined("counter:3"))

        // Events on the left topic are refused by the server.
        await #expect(throws: ChannelClientError.channelError(reason: "not_joined")) {
            try await counter.push("echo")
        }
        await client.disconnect()
    }

    @Test("connection states are observable: connecting → connected → closed")
    func stateStream() async throws {
        let harness = try ClientHarness()
        let client = harness.makeClient()
        let states = await client.states()
        var iterator = states.makeAsyncIterator()
        #expect(await iterator.next() == .closed)

        try await client.connect()
        #expect(await iterator.next() == .connecting)
        #expect(await iterator.next() == .connected)

        await client.disconnect()
        #expect(await iterator.next() == .closed)
    }
}
