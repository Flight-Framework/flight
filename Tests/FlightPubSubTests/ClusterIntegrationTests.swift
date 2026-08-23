import Foundation
import Testing
import FlightPubSub
import FlightPubSubTesting

/// Multi-node topologies over the in-memory transport: what the seam
/// promises — consumers against `PubSub` can't tell one node from
/// twenty — exercised end to end.
@Suite("Cluster integration", .timeLimit(.minutes(1)))
struct ClusterIntegrationTests {

    private struct Node {
        let pubsub: ClusteredPubSub
        let relay: Task<Void, Never>

        static func join(_ cluster: InMemoryCluster, id: String) -> Node {
            let pubsub = ClusteredPubSub(
                local: LocalPubSub(),
                adapter: cluster.makeAdapter(),
                nodeID: id
            )
            return Node(pubsub: pubsub, relay: Task { await pubsub.runIncomingRelay() })
        }

        func shutdown() async {
            relay.cancel()
            await relay.value
        }
    }

    @Test("publish on node A reaches subscribers on node B — and locally on A")
    func crossNodeDelivery() async {
        let cluster = InMemoryCluster()
        let a = Node.join(cluster, id: "a")
        let b = Node.join(cluster, id: "b")

        var onA = a.pubsub.subscribe("room:42").makeAsyncIterator()
        var onB = b.pubsub.subscribe("room:42").makeAsyncIterator()

        await a.pubsub.publish(msg("room:42", "hello", metadata: ["user": "u1"]))

        let receivedA = await onA.next()
        let receivedB = await onB.next()
        #expect(receivedA.map(text) == "hello")
        #expect(receivedB.map(text) == "hello")
        // Subscribers see identical metadata whether the message travelled
        // zero hops (A) or one (B).
        #expect(receivedA?.metadata == ["user": "u1"])
        #expect(receivedB?.metadata == ["user": "u1"])

        await a.shutdown()
        await b.shutdown()
    }

    @Test("delivery is symmetric: B to A as well as A to B")
    func symmetric() async {
        let cluster = InMemoryCluster()
        let a = Node.join(cluster, id: "a")
        let b = Node.join(cluster, id: "b")

        var onA = a.pubsub.subscribe("t").makeAsyncIterator()
        await b.pubsub.publish(msg("t", "from-b"))
        let received = await onA.next()
        #expect(received.map(text) == "from-b")

        await a.shutdown()
        await b.shutdown()
    }

    @Test("three nodes: everyone receives, publisher included, exactly in publish order")
    func threeNodes() async {
        let cluster = InMemoryCluster()
        let nodes = ["a", "b", "c"].map { Node.join(cluster, id: $0) }
        var iterators = nodes.map { $0.pubsub.subscribe("all").makeAsyncIterator() }

        for i in 0..<10 {
            await nodes[0].pubsub.publish(msg("all", "\(i)"))
        }
        for index in iterators.indices {
            for i in 0..<10 {
                let received = await iterators[index].next()
                #expect(received.map(text) == "\(i)")
            }
        }

        for node in nodes { await node.shutdown() }
    }

    @Test("an echoing transport (Redis-style) still yields exactly-one local delivery")
    func echoingTransport() async {
        let cluster = InMemoryCluster(echoesToOrigin: true)
        let a = Node.join(cluster, id: "a")
        let b = Node.join(cluster, id: "b")

        var onA = a.pubsub.subscribe("t").makeAsyncIterator()
        var onB = b.pubsub.subscribe("t").makeAsyncIterator()

        // B's receipt of m1 proves the wire delivered it everywhere — including
        // the echo back to A, which A's relay must have dropped by then or
        // will drop before m2's local yield can be overtaken (the relay
        // processes A's incoming in arrival order: echo(m1) precedes echo(m2)).
        await a.pubsub.publish(msg("t", "m1"))
        let firstOnB = await onB.next()
        #expect(firstOnB.map(text) == "m1")

        await a.pubsub.publish(msg("t", "m2"))
        let firstOnA = await onA.next()
        let secondOnA = await onA.next()
        #expect(firstOnA.map(text) == "m1")
        #expect(secondOnA.map(text) == "m2")  // a delivered echo would appear here as a duplicate "m1"

        await a.shutdown()
        await b.shutdown()
    }

    @Test("topic isolation holds across the cluster")
    func crossNodeTopicIsolation() async {
        let cluster = InMemoryCluster()
        let a = Node.join(cluster, id: "a")
        let b = Node.join(cluster, id: "b")

        var lobbyOnB = b.pubsub.subscribe("lobby").makeAsyncIterator()
        await a.pubsub.publish(msg("game", "not-for-lobby"))
        await a.pubsub.publish(msg("lobby", "for-lobby"))

        let received = await lobbyOnB.next()
        #expect(received.map(text) == "for-lobby")

        await a.shutdown()
        await b.shutdown()
    }

    @Test("a departed node stops receiving; the rest of the cluster is unaffected")
    func nodeDeparture() async {
        let cluster = InMemoryCluster()
        let a = Node.join(cluster, id: "a")
        let bAdapter = cluster.makeAdapter()
        let b = ClusteredPubSub(local: LocalPubSub(), adapter: bAdapter, nodeID: "b")
        let bRelay = Task { await b.runIncomingRelay() }
        let c = Node.join(cluster, id: "c")

        bAdapter.disconnect()
        await bRelay.value  // relay ends because the incoming stream finished

        var onC = c.pubsub.subscribe("t").makeAsyncIterator()
        await a.pubsub.publish(msg("t", "still-works"))
        let received = await onC.next()
        #expect(received.map(text) == "still-works")

        await a.shutdown()
        await c.shutdown()
    }

    @Test("consumers coded against `any PubSub` are node-count transparent")
    func protocolTransparency() async {
        // The same consumer function, handed a local and a clustered PubSub.
        func consumer(_ pubsub: any PubSub) async -> String? {
            var iterator = pubsub.subscribe("transparent").makeAsyncIterator()
            await pubsub.publish(msg("transparent", "works"))
            return (await iterator.next()).map(text)
        }

        #expect(await consumer(LocalPubSub()) == "works")

        let cluster = InMemoryCluster()
        let node = Node.join(cluster, id: "solo")
        #expect(await consumer(node.pubsub) == "works")
        await node.shutdown()
    }
}
