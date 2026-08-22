import Testing
@testable import FlightPresence

/// Direct unit coverage of the ORSWOT building blocks (design §4). The
/// convergence *property* — commutativity, associativity, idempotence
/// under arbitrary interleavings — is asserted wholesale in
/// `CRDTConvergenceTests`; these pin the individual behaviors that make
/// the property hold.
@Suite("Presence CRDT — observed-remove semantics (§4)", .timeLimit(.minutes(1)))
struct CRDTTests {

    private let nodeA = PresenceReplicaID(name: "a", boot: "boot-a")
    private let nodeB = PresenceReplicaID(name: "b", boot: "boot-b")

    private func record(_ key: String, topic: String = "room:1", ref: String = "r", status: String = "online") -> PresenceRecord {
        PresenceRecord(topic: topic, key: key, ref: ref, payload: ["status": status])
    }

    // MARK: - DotContext

    @Test("context observes dots and compacts contiguous runs into the version vector")
    func contextCompaction() {
        var context = DotContext()
        let d1 = PresenceDot(replica: nodeA, counter: 1)
        let d3 = PresenceDot(replica: nodeA, counter: 3)

        context.insert(d3)
        #expect(context.contains(d3))
        #expect(!context.contains(d1))
        #expect(context.versions[nodeA] == nil)  // gap: cloud only

        context.insert(d1)
        #expect(context.versions[nodeA] == 1)    // 1 compacts; 3 still clouded
        context.insert(PresenceDot(replica: nodeA, counter: 2))
        #expect(context.versions[nodeA] == 3)    // gap filled: whole run compacts
        #expect(context.cloud.isEmpty)
    }

    @Test("extend claims a whole contiguous prefix and absorbs clouded dots")
    func contextExtend() {
        var context = DotContext()
        context.insert(PresenceDot(replica: nodeA, counter: 4))
        context.extend(nodeA, through: 5)
        #expect(context.versions[nodeA] == 5)
        #expect(context.cloud.isEmpty)
        #expect(context.contains(PresenceDot(replica: nodeA, counter: 2)))
    }

    @Test("context merge is a sound union under partial overlap")
    func contextMerge() {
        var left = DotContext()
        left.extend(nodeA, through: 2)
        var right = DotContext()
        right.insert(PresenceDot(replica: nodeA, counter: 3))
        right.extend(nodeB, through: 1)

        left.merge(right)
        #expect(left.versions[nodeA] == 3)  // 1-2 from left, 3 clouded in right, compacted
        #expect(left.versions[nodeB] == 1)
        #expect(left.cloud.isEmpty)
    }

    // MARK: - Add / remove / observed-remove

    @Test("add then remove round-trips through join on another replica")
    func addRemoveRoundTrip() {
        var origin = PresenceCRDTState()
        var mirror = PresenceCRDTState()
        let dot = PresenceDot(replica: nodeA, counter: 1)

        let addDelta = origin.add(record("user:7"), at: dot)
        mirror.join(addDelta)
        #expect(mirror.entries[dot] == record("user:7"))

        let removeDelta = origin.remove([dot])
        mirror.join(removeDelta)
        #expect(mirror.entries.isEmpty)
        #expect(origin == mirror)
    }

    @Test("a remove delivered before its add wins — the add can never resurrect (§4)")
    func removeBeforeAdd() {
        var origin = PresenceCRDTState()
        var mirror = PresenceCRDTState()
        let dot = PresenceDot(replica: nodeA, counter: 1)

        let addDelta = origin.add(record("user:7"), at: dot)
        let removeDelta = origin.remove([dot])

        mirror.join(removeDelta)   // reordered gossip: remove first
        mirror.join(addDelta)
        #expect(mirror.entries.isEmpty)
    }

    @Test("a remote remove never destroys a concurrent add elsewhere (§4)")
    func concurrentAddSurvivesRemove() {
        var a = PresenceCRDTState()
        var b = PresenceCRDTState()

        let dotA = PresenceDot(replica: nodeA, counter: 1)
        _ = a.add(record("user:7", ref: "ra"), at: dotA)
        let removeDelta = a.remove([dotA])

        // Concurrently, B adds its own presence for the same key.
        let dotB = PresenceDot(replica: nodeB, counter: 1)
        _ = b.add(record("user:7", ref: "rb"), at: dotB)

        // A's remove reaches B: it removes exactly A's observed tag.
        b.join(removeDelta)
        #expect(b.entries[dotB] == record("user:7", ref: "rb"))
        #expect(b.entries.count == 1)
    }

    @Test("duplicate delta delivery is idempotent")
    func duplicateDelivery() {
        var origin = PresenceCRDTState()
        var mirror = PresenceCRDTState()
        let dot = PresenceDot(replica: nodeA, counter: 1)
        let delta = origin.add(record("user:7"), at: dot)

        let first = mirror.join(delta)
        let second = mirror.join(delta)
        #expect(first.added.count == 1)
        #expect(second.isEmpty)
        #expect(mirror.entries.count == 1)
    }

    @Test("replace carries the removal and the addition in one delta (§6 update)")
    func replaceDelta() {
        var origin = PresenceCRDTState()
        var mirror = PresenceCRDTState()
        let d1 = PresenceDot(replica: nodeA, counter: 1)
        let d2 = PresenceDot(replica: nodeA, counter: 2)

        mirror.join(origin.add(record("user:7", status: "online"), at: d1))
        let delta = origin.replace(d1, with: record("user:7", status: "away"), at: d2)
        let changes = mirror.join(delta)

        #expect(changes.added.map(\.0) == [d2])
        #expect(changes.removed.map(\.0) == [d1])
        #expect(mirror == origin)
    }

    // MARK: - Snapshot anti-entropy

    @Test("a snapshot repairs a lost add and a lost remove in one join")
    func snapshotRepairs() {
        var origin = PresenceCRDTState()
        var mirror = PresenceCRDTState()

        let d1 = PresenceDot(replica: nodeA, counter: 1)
        let d2 = PresenceDot(replica: nodeA, counter: 2)
        mirror.join(origin.add(record("user:1", ref: "r1"), at: d1))
        _ = origin.remove([d1])                          // remove delta LOST
        _ = origin.add(record("user:2", ref: "r2"), at: d2)  // add delta LOST

        mirror.join(origin.snapshot(of: nodeA, clock: 2))
        #expect(mirror.entries[d1] == nil)
        #expect(mirror.entries[d2] == record("user:2", ref: "r2"))
    }

    @Test("a snapshot never touches other replicas' entries")
    func snapshotIsScoped() {
        var a = PresenceCRDTState()
        var b = PresenceCRDTState()
        var observer = PresenceCRDTState()

        observer.join(a.add(record("user:a", ref: "ra"), at: PresenceDot(replica: nodeA, counter: 1)))
        observer.join(b.add(record("user:b", ref: "rb"), at: PresenceDot(replica: nodeB, counter: 1)))

        // A's snapshot claims only A's range; B's entry must survive.
        observer.join(a.snapshot(of: nodeA, clock: 1))
        #expect(observer.entries.count == 2)
    }

    // MARK: - Eviction

    @Test("evict removes exactly one replica's entries and forgets its context")
    func evict() {
        var state = PresenceCRDTState()
        var a = PresenceCRDTState()
        var b = PresenceCRDTState()
        state.join(a.add(record("user:a", ref: "ra"), at: PresenceDot(replica: nodeA, counter: 1)))
        state.join(b.add(record("user:b", ref: "rb"), at: PresenceDot(replica: nodeB, counter: 1)))

        let evicted = state.evict(nodeA)
        #expect(evicted.count == 1)
        #expect(state.entries.count == 1)
        #expect(state.context.versions[nodeA] == nil)
        #expect(state.context.versions[nodeB] == 1)
    }
}
