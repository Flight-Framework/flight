import Foundation
import Testing
import FlightPubSub
import FlightPubSubTesting

@Suite("ClusteredPubSub — the seam composition", .timeLimit(.minutes(1)))
struct ClusteredPubSubTests {

    struct BrokenWire: Error {}

    private func makeNode(nodeID: String = "node-under-test") -> (ClusteredPubSub, RecordingAdapter) {
        let adapter = RecordingAdapter()
        let clustered = ClusteredPubSub(local: LocalPubSub(), adapter: adapter, nodeID: nodeID)
        return (clustered, adapter)
    }

    // MARK: - Publish path

    @Test("publish fans out locally AND broadcasts through the adapter")
    func publishDoesBoth() async {
        let (clustered, adapter) = makeNode()
        var iterator = clustered.subscribe("room:1").makeAsyncIterator()

        await clustered.publish(msg("room:1", "hello", metadata: ["user": "abc"]))

        let received = await iterator.next()
        #expect(received.map(text) == "hello")
        // Local subscribers see the caller's metadata untouched — no stamp.
        #expect(received?.metadata == ["user": "abc"])

        #expect(adapter.broadcasts.count == 1)
        let broadcast = adapter.broadcasts[0]
        #expect(text(broadcast) == "hello")
        // The wire copy carries the origin stamp plus the caller's metadata.
        #expect(broadcast.metadata[ClusteredPubSub.originMetadataKey] == "node-under-test")
        #expect(broadcast.metadata["user"] == "abc")
    }

    @Test("a caller-supplied value under the reserved origin key is overwritten")
    func reservedKeyOverwritten() async {
        let (clustered, adapter) = makeNode()
        await clustered.publish(
            msg("t", "x", metadata: [ClusteredPubSub.originMetadataKey: "forged"])
        )
        #expect(adapter.broadcasts[0].metadata[ClusteredPubSub.originMetadataKey] == "node-under-test")
    }

    @Test("broadcast failure is swallowed: local delivery unaffected, publish does not throw")
    func broadcastFailureIsContained() async {
        let (clustered, adapter) = makeNode()
        adapter.setBroadcastError(BrokenWire())
        var iterator = clustered.subscribe("room:1").makeAsyncIterator()

        await clustered.publish(msg("room:1", "survives"))

        let received = await iterator.next()
        #expect(received.map(text) == "survives")
        #expect(adapter.broadcasts.isEmpty)

        // And the node recovers once the wire does.
        adapter.setBroadcastError(nil)
        await clustered.publish(msg("room:1", "recovered"))
        #expect(adapter.broadcasts.count == 1)
    }

    // MARK: - Incoming relay path

    @Test("a foreign incoming message reaches local subscribers, origin stamp stripped")
    func foreignIncomingDelivered() async {
        let (clustered, adapter) = makeNode()
        var iterator = clustered.subscribe("room:1").makeAsyncIterator()
        let relay = Task { await clustered.runIncomingRelay() }

        adapter.inject(
            msg("room:1", "from-afar", metadata: [
                ClusteredPubSub.originMetadataKey: "some-other-node",
                "user": "xyz",
            ])
        )

        let received = await iterator.next()
        #expect(received.map(text) == "from-afar")
        #expect(received?.metadata == ["user": "xyz"])

        relay.cancel()
        await relay.value
    }

    @Test("a self-originated echo is dropped — no duplicate local delivery")
    func ownEchoDropped() async {
        let (clustered, adapter) = makeNode()
        var iterator = clustered.subscribe("room:1").makeAsyncIterator()
        let relay = Task { await clustered.runIncomingRelay() }

        // The relay consumes in order: were the echo delivered, it would
        // arrive before the foreign sentinel that follows it.
        adapter.inject(msg("room:1", "echo", metadata: [ClusteredPubSub.originMetadataKey: "node-under-test"]))
        adapter.inject(msg("room:1", "sentinel", metadata: [ClusteredPubSub.originMetadataKey: "elsewhere"]))

        let received = await iterator.next()
        #expect(received.map(text) == "sentinel")

        relay.cancel()
        await relay.value
    }

    @Test("an unstamped incoming message (adapter without origin info) is delivered")
    func unstampedIncomingDelivered() async {
        let (clustered, adapter) = makeNode()
        var iterator = clustered.subscribe("room:1").makeAsyncIterator()
        let relay = Task { await clustered.runIncomingRelay() }

        adapter.inject(msg("room:1", "bare"))
        let received = await iterator.next()
        #expect(received.map(text) == "bare")
        #expect(received?.metadata.isEmpty == true)

        relay.cancel()
        await relay.value
    }

    @Test("the relay ends when the adapter's incoming stream finishes")
    func relayEndsWithStream() async {
        let (clustered, adapter) = makeNode()
        let relay = Task { await clustered.runIncomingRelay() }
        adapter.finishIncoming()
        await relay.value  // returning at all is the assertion
    }

    @Test("incoming messages are relayed in arrival order")
    func relayPreservesOrder() async {
        let (clustered, adapter) = makeNode()
        var iterator = clustered.subscribe("seq").makeAsyncIterator()
        let relay = Task { await clustered.runIncomingRelay() }

        for i in 0..<50 {
            adapter.inject(msg("seq", "\(i)", metadata: [ClusteredPubSub.originMetadataKey: "peer"]))
        }
        for i in 0..<50 {
            let received = await iterator.next()
            #expect(received.map(text) == "\(i)")
        }

        relay.cancel()
        await relay.value
    }
}

/// The seam's scaling ceiling, and how an adapter opts out of it.
@Suite("Topic interest", .timeLimit(.minutes(1)))
struct TopicInterestTests {

    private func clustered(_ adapter: RecordingAdapter) -> ClusteredPubSub {
        ClusteredPubSub(local: LocalPubSub(), adapter: adapter, nodeID: "n")
    }

    @Test("the first subscriber to a topic is announced, later ones are not")
    func firstSubscriberAnnounced() async {
        // The seam carried no interest signal at all, so an adapter had no
        // way to subscribe per topic on the wire — every node had to take the
        // whole cluster's firehose. Fine at small topic counts, a fan-in
        // ceiling at large ones, and unliftable without changing the
        // protocol. This is that change.
        let adapter = RecordingAdapter()
        let pubsub = clustered(adapter)

        let first = pubsub.subscribe("room:1")
        #expect(adapter.subscribedTopics == ["room:1"])

        // A second subscriber to the same topic is not a second wire
        // subscription; the adapter should not have to debounce.
        let second = pubsub.subscribe("room:1")
        #expect(adapter.subscribedTopics == ["room:1"])

        _ = first
        _ = second
    }

    @Test("the last unsubscribe is announced, earlier ones are not")
    func lastUnsubscribeAnnounced() async {
        let adapter = RecordingAdapter()
        let pubsub = clustered(adapter)

        var first: AsyncStream<Message>? = pubsub.subscribe("room:1")
        var second: AsyncStream<Message>? = pubsub.subscribe("room:1")

        first = nil
        for _ in 0..<100 where adapter.unsubscribedTopics.isEmpty { await Task.yield() }
        #expect(adapter.unsubscribedTopics.isEmpty, "a topic still has a subscriber")

        second = nil
        for _ in 0..<100 where adapter.unsubscribedTopics.isEmpty { await Task.yield() }
        #expect(adapter.unsubscribedTopics == ["room:1"])

        _ = first
        _ = second
    }

    @Test("resubscribing after the last leave announces again")
    func resubscribeAnnouncesAgain() async {
        let adapter = RecordingAdapter()
        let pubsub = clustered(adapter)

        var stream: AsyncStream<Message>? = pubsub.subscribe("room:1")
        stream = nil
        for _ in 0..<100 where adapter.unsubscribedTopics.isEmpty { await Task.yield() }

        let again = pubsub.subscribe("room:1")
        #expect(adapter.subscribedTopics == ["room:1", "room:1"])
        _ = again
        _ = stream
    }

    @Test("a firehose adapter needs neither callback")
    func firehoseAdapterCompiles() async {
        // The defaults are what keep this additive: an adapter written before
        // these existed still conforms, and still gets every message.
        struct Firehose: DistributedPubSubAdapter {
            func broadcast(_ message: Message) async throws {}
            func incoming() -> AsyncStream<Message> { AsyncStream { _ in } }
        }
        let pubsub = ClusteredPubSub(local: LocalPubSub(), adapter: Firehose(), nodeID: "n")
        let stream = pubsub.subscribe("room:1")
        await pubsub.publish(Message(topic: "room:1", payload: Data("hi".utf8)))
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() != nil)
    }
}
