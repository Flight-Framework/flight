import FlightChannelsProtocol
import FlightPresenceProtocol
import Testing

/// The shared client state machine (design §6): state-then-diffs, update
/// normalization, ref idempotence. The JS helper mirrors these rules; its
/// test suite asserts the same cases.
@Suite("PresenceSync — the client diff rules (§6)", .timeLimit(.minutes(1)))
struct PresenceSyncTests {

    private func statePayload(_ entries: [String: [PresenceMeta]]) -> JSONValue {
        PresenceWire.json(entries: entries)
    }

    private func diffPayload(joins: [String: [PresenceMeta]] = [:], leaves: [String: [PresenceMeta]] = [:]) -> JSONValue {
        PresenceWire.diffJSON(joins: joins, leaves: leaves)
    }

    @Test("state replaces the view and reports the difference")
    func applyState() {
        var sync = PresenceSync()
        let change = sync.applyState(statePayload([
            "user:7": [PresenceMeta(ref: "a1", payload: ["status": "online"])]
        ]))
        #expect(change.joins["user:7"]?.count == 1)
        #expect(change.leaves.isEmpty)
        #expect(sync.list.map(\.key) == ["user:7"])

        // A later state (rejoin) reports exactly who came and went.
        let second = sync.applyState(statePayload([
            "user:9": [PresenceMeta(ref: "b1", payload: [:])]
        ]))
        #expect(second.joins.keys.sorted() == ["user:9"])
        #expect(second.leaves.keys.sorted() == ["user:7"])
        #expect(sync.list.map(\.key) == ["user:9"])
    }

    @Test("join diff adds a meta; leave diff removes by ref; key gone on last meta (§2)")
    func joinAndLeave() {
        var sync = PresenceSync()
        sync.applyDiff(diffPayload(joins: [
            "user:7": [PresenceMeta(ref: "a1", payload: [:]), PresenceMeta(ref: "a2", payload: [:])]
        ]))
        #expect(sync.entries["user:7"]?.count == 2)

        let change = sync.applyDiff(diffPayload(leaves: [
            "user:7": [PresenceMeta(ref: "a1", payload: [:])]
        ]))
        #expect(change.leaves["user:7"]?.map(\.ref) == ["a1"])
        #expect(sync.entries["user:7"]?.map(\.ref) == ["a2"])

        sync.applyDiff(diffPayload(leaves: ["user:7": [PresenceMeta(ref: "a2", payload: [:])]]))
        #expect(sync.entries.isEmpty)
    }

    @Test("an update diff (leave+join, same ref) normalizes to an in-place change — no flap")
    func updateNormalization() {
        var sync = PresenceSync()
        sync.applyDiff(diffPayload(joins: ["user:7": [PresenceMeta(ref: "a1", payload: ["status": "online"])]]))

        let change = sync.applyDiff(diffPayload(
            joins: ["user:7": [PresenceMeta(ref: "a1", payload: ["status": "away"])]],
            leaves: ["user:7": [PresenceMeta(ref: "a1", payload: ["status": "online"])]]
        ))
        #expect(change.leaves.isEmpty, "an update must not report a leave")
        #expect(change.joins["user:7"]?.first?.payload == ["status": "away"])
        #expect(sync.entries["user:7"]?.count == 1)
        #expect(sync.entries["user:7"]?.first?.payload == ["status": "away"])
    }

    @Test("a re-delivered join for a known ref upserts, never duplicates")
    func joinIdempotence() {
        var sync = PresenceSync()
        let meta = PresenceMeta(ref: "a1", payload: ["status": "online"])
        sync.applyDiff(diffPayload(joins: ["user:7": [meta]]))
        let change = sync.applyDiff(diffPayload(joins: ["user:7": [meta]]))
        #expect(change.isEmpty)
        #expect(sync.entries["user:7"]?.count == 1)
    }

    @Test("a leave for an unknown ref is a no-op and reports nothing")
    func leaveUnknownRef() {
        var sync = PresenceSync()
        let change = sync.applyDiff(diffPayload(leaves: ["user:7": [PresenceMeta(ref: "zz", payload: [:])]]))
        #expect(change.isEmpty)
        #expect(sync.entries.isEmpty)
    }

    @Test("state overlap with a concurrent diff converges either way (§6 ordering)")
    func stateDiffOverlap() {
        // The state was computed after the join it overlaps with: applying
        // the (older) diff afterwards must not duplicate.
        var sync = PresenceSync()
        let meta = PresenceMeta(ref: "a1", payload: [:])
        sync.applyState(statePayload(["user:7": [meta]]))
        sync.applyDiff(diffPayload(joins: ["user:7": [meta]]))
        #expect(sync.entries["user:7"]?.count == 1)
    }

    @Test("wire round-trip: entries → JSON → entries")
    func wireRoundTrip() {
        let entries = [
            "user:7": [PresenceMeta(ref: "a1", payload: ["status": "online", "device": "ios"])],
            "user:9": [PresenceMeta(ref: "b1", payload: [:]), PresenceMeta(ref: "b2", payload: ["x": "y"])],
        ]
        let decoded = PresenceWire.entries(from: PresenceWire.json(entries: entries))
        #expect(decoded == entries)
    }

    @Test("the wire meta flattens payload beside ref, exactly as the design's example (§6)")
    func wireShape() {
        let json = PresenceWire.json(meta: PresenceMeta(ref: "a1", payload: ["status": "online"]))
        #expect(json == .object(["ref": .string("a1"), "status": .string("online")]))
    }
}
