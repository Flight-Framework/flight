import FlightChannels
import FlightChannelsTesting
import FlightCore
import FlightPubSub
import FlightPubSubTesting
import FlightWeb
import FlightWebTesting
import Testing

/// The payoff, proven: "Channels code is identical whether the other
/// subscriber is on the same process or a different machine." Two complete
/// Flight apps — separate containers, separate LocalPubSubs — joined only
/// by PubSub's distributed-adapter seam over an in-memory cluster. Sockets
/// on different nodes share a room.
@Suite("Multi-node broadcast", .timeLimit(.minutes(1)))
struct MultiNodeTests {

    private struct Node {
        let harness: NodeHarness
        let relay: Task<Void, Never>

        struct NotClustered: Error {}

        static func boot(cluster: InMemoryCluster) throws -> Node {
            let harness = try NodeHarness(cluster: cluster)
            // The relay is the long-running half a real adapter module would
            // register as its service (PubSub README); tests run it directly.
            guard let clustered = try harness.container.resolve((any PubSub).self) as? ClusteredPubSub else {
                throw NotClustered()
            }
            return Node(harness: harness, relay: Task { await clustered.runIncomingRelay() })
        }

        func shutdown() async {
            relay.cancel()
            await relay.value
        }
    }

    private struct NodeHarness {
        let container: Container
        let client: TestClient

        init(cluster: InMemoryCluster) throws {
            struct NodeModule: FlightModule {
                static var dependencies: [any FlightModule.Type] { [FlightChannelsModule.self] }
                func configure(_ container: Container) throws {}
            }
            let container = Container()
            container.register(Configuration.self, scope: .singleton) { _ in Configuration() }
            container.register((any DistributedPubSubAdapter).self, scope: .singleton) { _ in
                cluster.makeAdapter()
            }
            container.register(ChannelEvents.self, scope: .singleton) { _ in ChannelEvents() }
            for moduleType in try Flight.resolveModuleOrder([NodeModule.self]) {
                let module = moduleType.init()
                try module.configure(container)
            }
            container.registerChannel("room:*") { container in
                RoomChannel(
                    broadcaster: try container.resolve(ChannelBroadcaster.self),
                    events: try container.resolve(ChannelEvents.self)
                )
            }
            container.registerChannelSocket("/socket")
            try container.freeze()
            self.container = container
            self.client = try TestClient(container: container)
        }

        func wire() async throws -> ChannelWireClient {
            ChannelWireClient(socket: try await client.webSocket("/socket"))
        }
    }

    @Test("a shout on node A reaches a socket joined on node B — code unchanged")
    func crossNodeBroadcast() async throws {
        let cluster = InMemoryCluster()
        let nodeA = try Node.boot(cluster: cluster)
        let nodeB = try Node.boot(cluster: cluster)

        let alice = try await nodeA.harness.wire()
        let bob = try await nodeB.harness.wire()
        _ = try await alice.join("room:42")
        _ = try await bob.join("room:42")

        try alice.send(ref: "2", topic: "room:42", event: "shout", payload: ["body": "over the wire"])

        let toBob = try await bob.expectEnvelope { $0.event == "shouted" }
        #expect(toBob?.payload == ["body": "over the wire"])
        let toAlice = try await alice.expectEnvelope { $0.event == "shouted" }
        #expect(toAlice?.payload == ["body": "over the wire"])

        alice.close()
        bob.close()
        await nodeA.shutdown()
        await nodeB.shutdown()
    }

    @Test("broadcast-excluding-origin holds across nodes: origin filtered, remote peer not")
    func crossNodeExclusion() async throws {
        let cluster = InMemoryCluster()
        let nodeA = try Node.boot(cluster: cluster)
        let nodeB = try Node.boot(cluster: cluster)

        let alice = try await nodeA.harness.wire()
        let bob = try await nodeB.harness.wire()
        _ = try await alice.join("room:9")
        _ = try await bob.join("room:9")

        try alice.send(ref: "2", topic: "room:9", event: "whisper_others", payload: ["psst": true])
        #expect(try await bob.expectEnvelope { $0.event == "whispered" } != nil)

        _ = try await alice.expectEnvelope { $0.ref == "2" }
        try alice.send(ref: "3", topic: "room:9", event: "echo", payload: ["marker": true])
        let next = try await alice.nextEnvelope()
        #expect(next?.ref == "3", "origin socket saw its own excluded whisper")

        alice.close()
        bob.close()
        await nodeA.shutdown()
        await nodeB.shutdown()
    }
}
