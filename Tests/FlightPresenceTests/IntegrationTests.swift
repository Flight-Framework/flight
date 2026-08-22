import FlightChannels
import FlightChannelsTesting
import FlightCore
import FlightPresenceProtocol
import FlightPubSub
import FlightPubSubTesting
import Testing
@testable import FlightPresence

/// The client protocol, end to end through the real stack (design §6):
/// upgrade handshake, ChannelSocketHandler, SocketSession, PubSub — with
/// wire-level assertions on exactly what a browser would receive.
@Suite("Full-stack client protocol (§6, §7)", .timeLimit(.minutes(1)))
struct IntegrationTests {

    @Test("on join: reply first, then flight:presence_state with the joiner included")
    func joinThenState() async throws {
        let node = try PresenceNode(name: "solo")
        defer { Task { await node.shutdown() } }

        let alice = try await node.wire(user: "alice")
        try await alice.join("room:1")
        let state = try await alice.next(event: PresenceEvent.state)

        #expect(state.topic == "room:1")
        let entries = PresenceWire.entries(from: state.payload)
        #expect(entries.keys.sorted() == ["alice"])
        #expect(entries["alice"]?.first?.payload == ["status": "online"])
    }

    @Test("a second join reaches existing members as a diff; the joiner gets full state")
    func secondJoinDiffs() async throws {
        let node = try PresenceNode(name: "solo")
        defer { Task { await node.shutdown() } }

        let alice = try await node.wire(user: "alice")
        try await alice.join("room:1")
        _ = try await alice.next(event: PresenceEvent.state)

        let bob = try await node.wire(user: "bob")
        try await bob.join("room:1")
        let bobState = try await bob.next(event: PresenceEvent.state)
        #expect(PresenceWire.entries(from: bobState.payload).keys.sorted() == ["alice", "bob"])

        let diff = try await alice.next(event: PresenceEvent.diff)
        let joins = PresenceWire.entries(from: diff.payload["joins"] ?? .null)
        let leaves = PresenceWire.entries(from: diff.payload["leaves"] ?? .null)
        #expect(joins.keys.sorted() == ["bob"])
        #expect(leaves.isEmpty)
    }

    @Test("socket close is a leave diff for remaining members; last meta only (§2)")
    func closeEmitsLeave() async throws {
        let node = try PresenceNode(name: "solo")
        defer { Task { await node.shutdown() } }

        let alice = try await node.wire(user: "alice")
        try await alice.join("room:1")
        _ = try await alice.next(event: PresenceEvent.state)

        // Bob is present twice — two tabs.
        let bobTab1 = try await node.wire(user: "bob")
        let bobTab2 = try await node.wire(user: "bob")
        try await bobTab1.join("room:1")
        try await bobTab2.join("room:1")
        _ = try await alice.next(event: PresenceEvent.diff)
        _ = try await alice.next(event: PresenceEvent.diff)

        // Tab 1 closes: a leave diff for that meta — but bob still has
        // one meta, so the *key* must still be present server-side.
        bobTab1.close()
        let firstLeave = try await alice.next(event: PresenceEvent.diff)
        let leaves1 = PresenceWire.entries(from: firstLeave.payload["leaves"] ?? .null)
        #expect(leaves1.keys.sorted() == ["bob"])
        #expect(await node.presence.list(topic: "room:1").contains { $0.key == "bob" && $0.metas.count == 1 })

        // Tab 2 closes: now bob is genuinely gone.
        bobTab2.close()
        _ = try await alice.next(event: PresenceEvent.diff)
        try await eventually("bob fully gone") {
            await node.presence.list(topic: "room:1").allSatisfy { $0.key != "bob" }
        }
    }

    @Test("client flight:leave untracks that topic only")
    func clientLeave() async throws {
        let node = try PresenceNode(name: "solo")
        defer { Task { await node.shutdown() } }

        let alice = try await node.wire(user: "alice")
        try await alice.join("room:1")
        _ = try await alice.next(event: PresenceEvent.state)

        let bob = try await node.wire(user: "bob")
        try await bob.join("room:1")
        try await bob.join("room:2")
        _ = try await alice.next(event: PresenceEvent.diff)

        try bob.send(ref: "l1", topic: "room:1", event: "flight:leave")
        let diff = try await alice.next(event: PresenceEvent.diff)
        let leaves = PresenceWire.entries(from: diff.payload["leaves"] ?? .null)
        #expect(leaves.keys.sorted() == ["bob"])
        // Bob's other room is untouched.
        #expect(await node.presence.list(topic: "room:2").map(\.key) == ["bob"])
    }

    @Test("an update flows as leave+join of the same ref and normalizes client-side (§6)")
    func updateNormalization() async throws {
        let node = try PresenceNode(name: "solo")
        defer { Task { await node.shutdown() } }

        let alice = try await node.wire(user: "alice")
        try await alice.join("room:1")
        var aliceView = PresenceSync()
        aliceView.applyState((try await alice.next(event: PresenceEvent.state)).payload)

        let bob = try await node.wire(user: "bob")
        try await bob.join("room:1")
        aliceView.applyDiff((try await alice.next(event: PresenceEvent.diff)).payload)
        let refBefore = aliceView.entries["bob"]?.first?.ref

        try bob.send(ref: "s1", topic: "room:1", event: "status", payload: .object(["status": .string("away")]))
        let diff = try await alice.next(event: PresenceEvent.diff)

        // Raw wire shape: leave of the old meta, join of the new, same ref.
        let joins = PresenceWire.entries(from: diff.payload["joins"] ?? .null)
        let leaves = PresenceWire.entries(from: diff.payload["leaves"] ?? .null)
        #expect(joins["bob"]?.map(\.ref) == leaves["bob"]?.map(\.ref))

        // Normalized: no flap, payload changed in place, ref stable.
        let change = aliceView.applyDiff(diff.payload)
        #expect(change.leaves.isEmpty)
        #expect(aliceView.entries["bob"]?.count == 1)
        #expect(aliceView.entries["bob"]?.first?.ref == refBefore)
        #expect(aliceView.entries["bob"]?.first?.payload == ["status": "away"])
    }

    @Test("an anonymous socket can watch presence without being tracked")
    func watchOnly() async throws {
        let node = try PresenceNode(name: "solo")
        defer { Task { await node.shutdown() } }

        let watcher = try await node.wire(user: nil)
        try await watcher.join("room:1")
        let empty = try await watcher.next(event: PresenceEvent.state)
        #expect(empty.payload == .object([:]))

        let alice = try await node.wire(user: "alice")
        try await alice.join("room:1")
        let diff = try await watcher.next(event: PresenceEvent.diff)
        #expect(PresenceWire.entries(from: diff.payload["joins"] ?? .null).keys.sorted() == ["alice"])
        #expect(await node.presence.list(topic: "room:1").map(\.key) == ["alice"])
    }
}

/// Module wiring and mode detection (design §9).
@Suite("Module wiring (§9)", .timeLimit(.minutes(1)))
struct ModuleTests {

    @Test("no adapter ⇒ single-node mode; presence resolves; module contributes a service")
    func singleNodeDetection() async throws {
        let node = try PresenceNode(name: "solo")
        defer { Task { await node.shutdown() } }
        #expect(node.tracker.mode == .singleNode)
        #expect(node.presence is PresenceTracker)
    }

    @Test("adapter without membership monitor ⇒ degraded heartbeat mode (§5.2)")
    func degradedDetection() async throws {
        let cluster = InMemoryCluster()
        let node = try PresenceNode(name: "a", cluster: cluster)
        defer { Task { await node.shutdown() } }
        #expect(node.tracker.mode == .heartbeatExpiry)
    }

    @Test("adapter plus membership monitor ⇒ membership mode (§5.1)")
    func membershipDetection() async throws {
        let cluster = InMemoryCluster()
        let node = try PresenceNode(name: "a", cluster: cluster, monitor: FakeMembershipMonitor())
        defer { Task { await node.shutdown() } }
        #expect(node.tracker.mode == .membership)
    }

    @Test("replica identity: configured name, fresh boot per process (§4 restart safety)")
    func replicaIdentity() async throws {
        let node = try PresenceNode(name: "web-1")
        defer { Task { await node.shutdown() } }
        #expect(node.tracker.replica.name == "web-1")
        #expect(!node.tracker.replica.boot.isEmpty)
        #expect(FlightPresenceModule.generateBoot() != FlightPresenceModule.generateBoot())
    }
}
