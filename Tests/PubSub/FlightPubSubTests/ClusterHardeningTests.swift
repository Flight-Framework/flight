import FlightPubSub
import FlightPubSubTesting
import Foundation
import Synchronization
import Testing

/// An adapter that never answers, for proving `publish` does not wait forever.
final class HangingAdapter: DistributedPubSubAdapter, @unchecked Sendable {
    func broadcast(_ message: Message) async throws {
        try await Task.sleep(for: .seconds(3600))
    }
    func incoming() -> AsyncStream<Message> {
        AsyncStream { _ in }
    }
}

/// An adapter that never answers **and never notices cancellation** —
/// blocking I/O bridged to async, or a continuation nobody resumes.
///
/// `HangingAdapter` sleeps, and `Task.sleep` unwinds on cancellation, so it
/// could not catch the defect this exists for: the timeout raced inside a
/// `withThrowingTaskGroup`, which awaits *all* its children at scope exit, so
/// `cancelAll()` only helped an adapter that responded to cancellation — and
/// `DistributedPubSubAdapter` has never required one to.
final class DeafAdapter: DistributedPubSubAdapter, @unchecked Sendable {
    private let parked = Mutex<[CheckedContinuation<Void, Never>]>([])

    func broadcast(_ message: Message) async throws {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            parked.withLock { $0.append(continuation) }
        }
    }

    func incoming() -> AsyncStream<Message> { AsyncStream { _ in } }

    /// Lets the parked broadcasts go, so the test leaves nothing behind.
    func release() {
        let waiting = parked.withLock { current -> [CheckedContinuation<Void, Never>] in
            let all = current
            current = []
            return all
        }
        for continuation in waiting { continuation.resume() }
    }
}

@Suite("Clustered hardening", .timeLimit(.minutes(1)))
struct ClusterHardeningTests {

    // MARK: A stalled adapter cannot stall the publisher

    @Test("publish gives up on a hung adapter instead of blocking forever")
    func broadcastTimesOut() async {
        // `publish` awaited `adapter.broadcast` with no bound. An adapter that
        // stopped answering — a wedged connection, a partitioned broker —
        // blocked every publisher in the process indefinitely, while local
        // delivery had already succeeded and nobody was waiting on anything
        // that would arrive.
        let clustered = ClusteredPubSub(
            local: LocalPubSub(),
            adapter: HangingAdapter(),
            nodeID: "slow-node",
            broadcastTimeout: .milliseconds(50))

        var iterator = clustered.subscribe("room:1").makeAsyncIterator()
        let clock = ContinuousClock()
        let elapsed = await clock.measure {
            await clustered.publish(msg("room:1", "hello"))
        }

        #expect(elapsed < .seconds(2), "publish waited \(elapsed) on a hung adapter")
        // And the local subscriber was served regardless.
        #expect(await iterator.next().map(text) == "hello")
    }

    @Test("the timeout bounds publish even against an adapter deaf to cancellation")
    func broadcastTimesOutWithoutCooperation() async {
        // Docs/pubsub.md: "an adapter that stops answering costs one remote
        // delivery, not the publisher's liveness." That held only for an
        // adapter that unwound on cancellation. The timeout child threw, the
        // deferred `cancelAll()` ran — and then the task group awaited every
        // child anyway, so a broadcast parked in non-cancellable work hung
        // `publish` for as long as it lasted, timeout or no timeout.
        let adapter = DeafAdapter()
        defer { adapter.release() }
        let clustered = ClusteredPubSub(
            local: LocalPubSub(), adapter: adapter,
            nodeID: "deaf-node", broadcastTimeout: .milliseconds(50))

        var iterator = clustered.subscribe("room:1").makeAsyncIterator()
        // Deliberately not `await publish(...)` directly: against the code
        // this pins, that call never returns, and a test that hangs is worse
        // than one that fails — the broadcast it waits on is uncancellable by
        // construction, so nothing would ever unwind it.
        let returned = Mutex(false)
        let publisher = Task {
            await clustered.publish(msg("room:1", "hello"))
            returned.withLock { $0 = true }
        }
        for _ in 0..<200 where !returned.withLock({ $0 }) {
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(
            returned.withLock { $0 },
            "publish did not return within 2s on an adapter deaf to cancellation")
        #expect(await iterator.next().map(text) == "hello")
        publisher.cancel()
    }

    @Test("no timeout still means wait, for callers who want that")
    func timeoutIsOptional() async {
        let clustered = ClusteredPubSub(
            local: LocalPubSub(), adapter: RecordingAdapter(),
            nodeID: "n", broadcastTimeout: nil)
        await clustered.publish(msg("room:1", "hello"))
        // A working adapter completes either way; this pins that nil is legal.
        #expect(true)
    }

    // MARK: Reserved keys never reach a subscriber

    @Test("a forged origin key is stripped from local delivery, not just the wire")
    func forgedOriginNeverReachesSubscribers() async {
        // The stamp was overwritten only on the outgoing copy. Local
        // subscribers on the publishing node received the caller's value
        // verbatim — the one place the documented "stripped on delivery"
        // guarantee did not hold, and the place where a forged value would be
        // read as authentic transport metadata.
        let adapter = RecordingAdapter()
        let clustered = ClusteredPubSub(local: LocalPubSub(), adapter: adapter, nodeID: "real-node")
        var iterator = clustered.subscribe("room:1").makeAsyncIterator()

        await clustered.publish(
            msg(
                "room:1", "hello",
                metadata: [
                    ClusteredPubSub.originMetadataKey: "impersonated-node",
                    ClusteredPubSub.instanceMetadataKey: "impersonated-instance",
                    "user": "u1",
                ]))

        let received = await iterator.next()
        #expect(received?.metadata == ["user": "u1"], "reserved keys must not survive to a subscriber")
        // The wire copy carries this node's real identity, not the forgery.
        #expect(adapter.broadcasts[0].metadata[ClusteredPubSub.originMetadataKey] == "real-node")
    }

    @Test("an incoming message's reserved keys are stripped too")
    func incomingReservedKeysStripped() async {
        let adapter = RecordingAdapter()
        let clustered = ClusteredPubSub(local: LocalPubSub(), adapter: adapter, nodeID: "here")
        var iterator = clustered.subscribe("room:1").makeAsyncIterator()
        let relay = Task { await clustered.runIncomingRelay() }

        adapter.inject(
            msg(
                "room:1", "remote",
                metadata: [
                    ClusteredPubSub.originMetadataKey: "elsewhere",
                    ClusteredPubSub.instanceMetadataKey: "elsewhere-instance",
                    "user": "u2",
                ]))

        #expect(await iterator.next()?.metadata == ["user": "u2"])
        relay.cancel()
        await relay.value
    }

    // MARK: Two nodes sharing a name

    @Test("nodes sharing a nodeID still deliver to each other")
    func nodeIDCollisionDoesNotSilenceDelivery() async {
        // Suppression keyed on nodeID, so two nodes configured with the same
        // one — a templated config, a copy-pasted deployment — each read the
        // other's messages as their own echo and dropped them. The two nodes
        // went deaf to each other in both directions, with nothing logged and
        // no error anywhere.
        let cluster = InMemoryCluster()
        let a = ClusteredPubSub(local: LocalPubSub(), adapter: cluster.makeAdapter(), nodeID: "same")
        let b = ClusteredPubSub(local: LocalPubSub(), adapter: cluster.makeAdapter(), nodeID: "same")

        var onB = b.subscribe("room:1").makeAsyncIterator()
        let relayA = Task { await a.runIncomingRelay() }
        let relayB = Task { await b.runIncomingRelay() }

        await a.publish(msg("room:1", "from-a"))
        #expect(await onB.next().map(text) == "from-a")

        relayA.cancel(); relayB.cancel()
        await relayA.value; await relayB.value
    }

    @Test("a node's own echo is still suppressed when IDs collide")
    func ownEchoStillSuppressedUnderCollision() async {
        let cluster = InMemoryCluster(echoesToOrigin: true)
        let a = ClusteredPubSub(local: LocalPubSub(), adapter: cluster.makeAdapter(), nodeID: "same")
        let b = ClusteredPubSub(local: LocalPubSub(), adapter: cluster.makeAdapter(), nodeID: "same")

        var onA = a.subscribe("room:1").makeAsyncIterator()
        let relayA = Task { await a.runIncomingRelay() }
        let relayB = Task { await b.runIncomingRelay() }

        // A publishes; the cluster echoes it back to A. A must see it once
        // (locally), not twice.
        await a.publish(msg("room:1", "once"))
        await b.publish(msg("room:1", "sentinel"))

        #expect(await onA.next().map(text) == "once")
        #expect(await onA.next().map(text) == "sentinel", "the echo must not have been delivered")

        relayA.cancel(); relayB.cancel()
        await relayA.value; await relayB.value
    }

    @Test("distinct instances have distinct tokens even with one nodeID")
    func instanceTokensAreUnique() {
        let a = ClusteredPubSub(local: LocalPubSub(), adapter: RecordingAdapter(), nodeID: "same")
        let b = ClusteredPubSub(local: LocalPubSub(), adapter: RecordingAdapter(), nodeID: "same")
        #expect(a.nodeID == b.nodeID)
        #expect(a.instanceToken != b.instanceToken)
    }
}

/// Dropped messages under a bounded buffer.
@Suite("Bounded buffer drops are counted", .timeLimit(.minutes(1)))
struct DroppedMessageTests {

    @Test("a full subscriber buffer records what it refused")
    func dropsAreCounted() async {
        // `yield` returns a result saying the message was dropped, and it was
        // discarded — so the one signal that a subscriber had fallen behind
        // went nowhere. At-most-once permits the drop; it does not require
        // hiding it.
        let pubsub = LocalPubSub(bufferingPolicy: .bufferingOldest(2))
        let stream = pubsub.subscribe("room:1")

        for index in 0..<10 {
            await pubsub.publish(msg("room:1", "m\(index)"))
        }

        #expect(pubsub.droppedCount == 8, "10 published into a buffer of 2")
        #expect(pubsub.droppedCounts["room:1"] == 8)
        _ = stream
    }

    @Test("nothing is dropped under the unbounded default")
    func unboundedDropsNothing() async {
        let pubsub = LocalPubSub()
        let stream = pubsub.subscribe("room:1")
        for index in 0..<100 {
            await pubsub.publish(msg("room:1", "m\(index)"))
        }
        #expect(pubsub.droppedCount == 0)
        _ = stream
    }

    @Test("a topic with no subscribers drops nothing")
    func noSubscribersIsNotADrop() async {
        let pubsub = LocalPubSub(bufferingPolicy: .bufferingOldest(1))
        await pubsub.publish(msg("room:empty", "m"))
        #expect(pubsub.droppedCount == 0)
    }
}
