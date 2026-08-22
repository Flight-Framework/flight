import FlightChannels
import FlightChannelsTesting
import FlightPresenceProtocol
import FlightPubSub
import FlightPubSubTesting
import Testing
@testable import FlightPresence

/// Distributed presence over the real seams (design §4, §5): two complete
/// Flight apps — separate containers, separate LocalPubSubs, their own
/// presence services — joined only by PubSub's distributed adapter over an
/// in-memory cluster wire.
@Suite("Multi-node presence (§4, §5)", .timeLimit(.minutes(2)))
struct MultiNodeTests {

    // MARK: - Convergence across nodes (§4)

    @Test("presences converge across nodes and reach remote clients as diffs")
    func crossNodePresence() async throws {
        let cluster = InMemoryCluster()
        let nodeA = try PresenceNode(name: "a", cluster: cluster)
        let nodeB = try PresenceNode(name: "b", cluster: cluster)
        defer { Task { await nodeA.shutdown(); await nodeB.shutdown() } }

        let alice = try await nodeA.wire(user: "alice")
        try await alice.join("room:1")
        _ = try await alice.next(event: PresenceEvent.state)

        let bob = try await nodeB.wire(user: "bob")
        try await bob.join("room:1")

        // Alice (node A) sees bob (node B) arrive as a diff…
        let diff = try await alice.next(event: PresenceEvent.diff)
        #expect(PresenceWire.entries(from: diff.payload["joins"] ?? .null).keys.sorted() == ["bob"])

        // …and both nodes' merged views agree (§4).
        try await eventually("views converge") {
            let viewA = await nodeA.presence.list(topic: "room:1").map(\.key)
            let viewB = await nodeB.presence.list(topic: "room:1").map(\.key)
            return viewA == ["alice", "bob"] && viewB == ["alice", "bob"]
        }
    }

    @Test("a late-booting node converges via startup sync, not by waiting out a heartbeat")
    func lateBootSync() async throws {
        let cluster = InMemoryCluster()
        // Slow heartbeats: convergence within the assertion window can only
        // come from the startup syncRequest/snapshot exchange (§9).
        var slow = PresenceNode.fastConfig
        slow["flight.presence.heartbeat-interval-seconds"] = "30"
        slow["flight.presence.down-after-seconds"] = "90"

        let nodeA = try PresenceNode(name: "a", cluster: cluster, configValues: slow)
        let alice = try await nodeA.wire(user: "alice")
        try await alice.join("room:1")
        _ = try await alice.next(event: PresenceEvent.state)

        let nodeB = try PresenceNode(name: "b", cluster: cluster, configValues: slow)
        defer { Task { await nodeA.shutdown(); await nodeB.shutdown() } }

        try await eventually("node B learned alice at boot", timeout: .seconds(3)) {
            await nodeB.presence.list(topic: "room:1").map(\.key) == ["alice"]
        }
        // And a client joining on B gets the remote entry in its state.
        let watcher = try await nodeB.wire(user: nil)
        try await watcher.join("room:1")
        let state = try await watcher.next(event: PresenceEvent.state)
        #expect(PresenceWire.entries(from: state.payload).keys.sorted() == ["alice"])
    }

    @Test("a remote leave reaches local clients")
    func remoteLeave() async throws {
        let cluster = InMemoryCluster()
        let nodeA = try PresenceNode(name: "a", cluster: cluster)
        let nodeB = try PresenceNode(name: "b", cluster: cluster)
        defer { Task { await nodeA.shutdown(); await nodeB.shutdown() } }

        let alice = try await nodeA.wire(user: "alice")
        try await alice.join("room:1")
        _ = try await alice.next(event: PresenceEvent.state)

        let bob = try await nodeB.wire(user: "bob")
        try await bob.join("room:1")
        _ = try await alice.next(event: PresenceEvent.diff)

        bob.close()
        let diff = try await alice.next(event: PresenceEvent.diff)
        #expect(PresenceWire.entries(from: diff.payload["leaves"] ?? .null).keys.sorted() == ["bob"])
        try await eventually("bob gone everywhere") {
            await nodeA.presence.list(topic: "room:1").map(\.key) == ["alice"]
        }
    }

    // MARK: - Node failure, degraded mode (§5.2)

    @Test("degraded mode: a crashed node's users leave after the timeout — delayed, as documented")
    func degradedNodeDeath() async throws {
        let cluster = InMemoryCluster()
        let nodeA = try PresenceNode(name: "a", cluster: cluster)
        let nodeB = try PresenceNode(name: "b", cluster: cluster)
        defer { Task { await nodeA.shutdown(); await nodeB.shutdown() } }

        let alice = try await nodeA.wire(user: "alice")
        try await alice.join("room:1")
        _ = try await alice.next(event: PresenceEvent.state)

        let bob = try await nodeB.wire(user: "bob")
        try await bob.join("room:1")
        _ = try await alice.next(event: PresenceEvent.diff)

        nodeB.crash()

        // Removal is delayed by up to down-after (0.5s here) — the
        // documented degraded-mode window (§5.2).
        let diff = try await alice.next(event: PresenceEvent.diff)
        #expect(PresenceWire.entries(from: diff.payload["leaves"] ?? .null).keys.sorted() == ["bob"])
        #expect(await nodeA.presence.list(topic: "room:1").map(\.key) == ["alice"])

        // After permdown (2s), the dead replica's state is purged.
        try await eventually("replica purged", timeout: .seconds(5)) {
            await nodeA.tracker.knownPeers().isEmpty
        }
    }

    @Test("degraded mode: a wrongly-evicted node that resumes gossiping flaps back in (§5.2)")
    func degradedFlapRecovery() async throws {
        // Tracker-level: drive gossip by hand so "the node went silent but
        // did not die" is precisely controllable.
        let config = PresenceConfiguration(
            nodeName: "a",
            heartbeatInterval: .milliseconds(100),
            downAfter: .milliseconds(300),
            permdownAfter: .seconds(30)
        )
        let (tracker, bus) = makeTracker(name: "a", mode: .heartbeatExpiry, configuration: config)
        let collector = DiffCollector(pubsub: bus, topic: "room:1")

        // A remote replica announces bob…
        let remote = PresenceReplicaID(name: "b", boot: "boot-b")
        var remoteState = PresenceCRDTState()
        _ = remoteState.add(
            PresenceRecord(topic: "room:1", key: "bob", ref: "rb-1", payload: [:]),
            at: PresenceDot(replica: remote, counter: 1)
        )
        let snapshot = PresenceGossipMessage.snapshot(from: remote, state: remoteState.snapshot(of: remote, clock: 1))
        await tracker.receiveGossip(Message(topic: PresenceGossip.topic, payload: PresenceGossipFrame.encode(snapshot)!))
        #expect(await tracker.list(topic: "room:1").map(\.key) == ["bob"])

        // …then falls silent past down-after: a spurious leave.
        try await Task.sleep(for: .milliseconds(400))
        await tracker.sweep()
        #expect(await tracker.list(topic: "room:1").isEmpty)
        #expect(await tracker.knownPeers() == [remote: false])

        // Gossip resumes: bob flaps back in as a join — no data lost.
        await tracker.receiveGossip(Message(topic: PresenceGossip.topic, payload: PresenceGossipFrame.encode(snapshot)!))
        #expect(await tracker.list(topic: "room:1").map(\.key) == ["bob"])

        try await eventually("leave then join diffs observed") { collector.diffs.count == 3 }
        let leaves = PresenceWire.entries(from: collector.diffs[1]["leaves"] ?? .null)
        let rejoins = PresenceWire.entries(from: collector.diffs[2]["joins"] ?? .null)
        #expect(leaves.keys.sorted() == ["bob"])
        #expect(rejoins.keys.sorted() == ["bob"])
    }

    // MARK: - Node failure, membership mode (§5.1)

    @Test("membership mode: node death is prompt — the monitor, not a timeout, drives eviction")
    func membershipNodeDeath() async throws {
        let cluster = InMemoryCluster()
        // Liveness timers far beyond the assertion window: only the
        // membership event can produce the leave.
        var config = PresenceNode.fastConfig
        config["flight.presence.down-after-seconds"] = "600"
        config["flight.presence.heartbeat-interval-seconds"] = "0.1"
        config["flight.presence.permdown-after-seconds"] = "1200"

        let monitorA = FakeMembershipMonitor()
        let nodeA = try PresenceNode(name: "a", cluster: cluster, monitor: monitorA, configValues: config)
        let nodeB = try PresenceNode(name: "b", cluster: cluster, monitor: FakeMembershipMonitor(), configValues: config)
        defer { Task { await nodeA.shutdown(); await nodeB.shutdown() } }

        let alice = try await nodeA.wire(user: "alice")
        try await alice.join("room:1")
        _ = try await alice.next(event: PresenceEvent.state)

        let bob = try await nodeB.wire(user: "bob")
        try await bob.join("room:1")
        _ = try await alice.next(event: PresenceEvent.diff)

        nodeB.crash()
        monitorA.emit(.down(node: "b"))

        let diff = try await alice.next(event: PresenceEvent.diff)
        #expect(PresenceWire.entries(from: diff.payload["leaves"] ?? .null).keys.sorted() == ["bob"])
        #expect(await nodeA.presence.list(topic: "room:1").map(\.key) == ["alice"])
    }

    @Test("membership mode: gossip from a down-declared node is ignored until the monitor says up")
    func membershipMonitorIsAuthoritative() async throws {
        let config = PresenceConfiguration(nodeName: "a", downAfter: .seconds(600), permdownAfter: .seconds(1200))
        let (tracker, _) = makeTracker(name: "a", mode: .membership, configuration: config)

        let remote = PresenceReplicaID(name: "b", boot: "boot-b")
        var remoteState = PresenceCRDTState()
        _ = remoteState.add(
            PresenceRecord(topic: "room:1", key: "bob", ref: "rb-1", payload: [:]),
            at: PresenceDot(replica: remote, counter: 1)
        )
        let snapshot = PresenceGossipMessage.snapshot(from: remote, state: remoteState.snapshot(of: remote, clock: 1))
        let frame = Message(topic: PresenceGossip.topic, payload: PresenceGossipFrame.encode(snapshot)!)

        await tracker.receiveGossip(frame)
        #expect(await tracker.list(topic: "room:1").map(\.key) == ["bob"])

        // SWIM says down: hidden promptly, and resumed gossip alone must
        // NOT resurrect — the monitor is authoritative (§5.1).
        await tracker.membershipEvent(.down(node: "b"))
        #expect(await tracker.list(topic: "room:1").isEmpty)
        await tracker.receiveGossip(frame)
        #expect(await tracker.list(topic: "room:1").isEmpty)

        // Monitor says up: the next gossip restores.
        await tracker.membershipEvent(.up(node: "b"))
        await tracker.receiveGossip(frame)
        #expect(await tracker.list(topic: "room:1").map(\.key) == ["bob"])
    }
}
