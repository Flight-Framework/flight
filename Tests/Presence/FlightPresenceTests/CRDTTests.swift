import Testing
@testable import FlightPresence

/// Direct unit coverage of the ORSWOT building blocks. The
/// convergence *property* — commutativity, associativity, idempotence
/// under arbitrary interleavings — is asserted wholesale in
/// `CRDTConvergenceTests`; these pin the individual behaviors that make
/// the property hold.
@Suite("Presence CRDT — observed-remove semantics", .timeLimit(.minutes(1)))
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

    @Test("a remove delivered before its add wins — the add can never resurrect")
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

    @Test("a remote remove never destroys a concurrent add elsewhere")
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

    @Test("replace carries the removal and the addition in one delta")
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

    // MARK: - A peer may not speak about our dots

    @Test("a frame claiming our dots is refused, not merged")
    func foreignClaimsAboutOurOwnDotsAreDropped() {
        // The concrete failure: a peer's frame whose context claims dots of
        // the *receiving* replica was merged unconditionally, raising our
        // version past our own clock. The receiver's next local `track` then
        // tripped `add`'s monotonic-counter precondition and killed the
        // process — one frame, one crash, from a buggy or malicious peer.
        var local = PresenceCRDTState()
        local.join(local.add(record("user:a", ref: "ra"), at: PresenceDot(replica: nodeA, counter: 1)))

        // Built the way a frame arrives: a snapshot from B, then B forges a
        // claim about A's counters into its context.
        var b = PresenceCRDTState()
        _ = b.add(record("user:b", ref: "rb"), at: PresenceDot(replica: nodeB, counter: 1))
        var frame = b.snapshot(of: nodeB, clock: 1)
        frame.forgeClaimForTesting(about: nodeA, through: 100)

        local.join(frame, ownReplica: nodeA)

        // Our own version is untouched; the peer's own claim is kept.
        #expect(local.context.versions[nodeA] == 1, "a peer moved our clock")
        #expect(local.context.versions[nodeB] == 1, "the peer's own claim was dropped too")
        #expect(local.entries.count == 2, "b's own entry still merged")

        // And the next local add — the operation that used to trap — works.
        local.join(local.add(record("user:a2", ref: "ra2"), at: PresenceDot(replica: nodeA, counter: 2)))
        #expect(local.entries.count == 3)
    }

    @Test("a locally-produced delta is joined unfiltered")
    func localDeltasAreNotFiltered() {
        // The filter is for the wire only: our own delta legitimately speaks
        // about our own dots, and filtering it would drop every local add.
        var local = PresenceCRDTState()
        var mirror = PresenceCRDTState()
        let delta = local.add(record("user:a", ref: "ra"), at: PresenceDot(replica: nodeA, counter: 1))
        mirror.join(delta)
        #expect(mirror.entries.count == 1)
    }

    @Test("the replica index stays in step with entries through every operation")
    func replicaIndexTracksEntries() {
        // `dots(of:)` reads the index and everything else reads `entries`, so
        // a missed index update would show as a state that looks right and
        // gossips wrong.
        var state = PresenceCRDTState()
        let d1 = PresenceDot(replica: nodeA, counter: 1)
        let d2 = PresenceDot(replica: nodeA, counter: 2)
        state.join(state.add(record("user:a", ref: "ra"), at: d1))
        #expect(Set(state.dots(of: nodeA)) == [d1])

        _ = state.replace(d1, with: record("user:a", ref: "ra", status: "away"), at: d2)
        #expect(Set(state.dots(of: nodeA)) == [d2])
        #expect(Set(state.entries.keys) == [d2])

        _ = state.remove([d2])
        #expect(state.dots(of: nodeA).isEmpty)
        #expect(state.entries.isEmpty)
    }

    @Test("a remote remove still removes, now that the pass is indexed")
    func indexedRemovalStillRemoves() {
        var a = PresenceCRDTState()
        var mirror = PresenceCRDTState()
        let dot = PresenceDot(replica: nodeA, counter: 1)
        mirror.join(a.add(record("user:a", ref: "ra"), at: dot))
        #expect(mirror.entries.count == 1)

        let changes = mirror.join(a.remove([dot]), ownReplica: nodeB)
        #expect(changes.removed.count == 1)
        #expect(mirror.entries.isEmpty)
        #expect(mirror.dots(of: nodeA).isEmpty)
    }
}
