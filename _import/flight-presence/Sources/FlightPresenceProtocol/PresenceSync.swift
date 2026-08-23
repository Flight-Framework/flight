import FlightChannelsProtocol

/// The net effect of applying one state or diff message: what actually
/// changed, after normalization. Keys map to the metas that joined
/// (including updated metas — same ref, new payload) or genuinely left.
public struct PresenceSyncChange: Sendable, Equatable {
    public let joins: [String: [PresenceMeta]]
    public let leaves: [String: [PresenceMeta]]

    public var isEmpty: Bool { joins.isEmpty && leaves.isEmpty }

    public init(joins: [String: [PresenceMeta]] = [:], leaves: [String: [PresenceMeta]] = [:]) {
        self.joins = joins
        self.leaves = leaves
    }
}

/// The client-side presence state machine: applies one
/// `flight:presence_state` and any number of `flight:presence_diff`
/// payloads to a maintained (key → metas) map, so application code sees a
/// list, not diff plumbing. Pure and platform-free — the Swift client
/// helper wraps it, server tests use it to assert the wire contract, and
/// the JS helper mirrors its rules exactly.
///
/// Normalization rules, shared by every helper:
/// - Within one diff, **leaves apply before joins.** A meta-only update
///   travels as a leave of the old meta and a join of the new one for the
///   same `ref`; leaves-first makes that an in-place replacement.
/// - Joins **upsert by ref**: a re-delivered join for a known ref replaces
///   that meta rather than duplicating it, so overlap between an initial
///   state and a concurrent diff is harmless.
/// - Leaves remove by ref; removing an absent ref is a no-op.
/// - The reported change is the *net* effect: an updated ref appears in
///   `joins` only — never as a leave/join flap — and a leave that removed
///   nothing is not reported.
public struct PresenceSync: Sendable, Equatable {
    /// The maintained view. Metas keep arrival order; an update replaces
    /// in place.
    public private(set) var entries: [String: [PresenceMeta]] = [:]

    public init() {}

    /// The current list, sorted by key for stable presentation.
    public var list: [PresenceEntry] {
        entries.keys.sorted().map { PresenceEntry(key: $0, metas: entries[$0]!) }
    }

    /// Replaces the whole view with a `flight:presence_state` payload.
    /// The change reports the difference from the previous view — so a
    /// rejoin's fresh state (Channels, reconnect-and-rejoin) surfaces
    /// exactly who came and went while the client was away.
    @discardableResult
    public mutating func applyState(_ payload: JSONValue) -> PresenceSyncChange {
        let incoming = PresenceWire.entries(from: payload)
        var joins: [String: [PresenceMeta]] = [:]
        var leaves: [String: [PresenceMeta]] = [:]

        for (key, newMetas) in incoming {
            let known = Dictionary(uniqueKeysWithValues: (entries[key] ?? []).map { ($0.ref, $0) })
            let joined = newMetas.filter { known[$0.ref] != $0 }
            if !joined.isEmpty { joins[key] = joined }
        }
        for (key, oldMetas) in entries {
            let incomingRefs = Set((incoming[key] ?? []).map(\.ref))
            let left = oldMetas.filter { !incomingRefs.contains($0.ref) }
            if !left.isEmpty { leaves[key] = left }
        }

        entries = incoming
        return PresenceSyncChange(joins: joins, leaves: leaves)
    }

    /// Applies a `flight:presence_diff` payload.
    @discardableResult
    public mutating func applyDiff(_ payload: JSONValue) -> PresenceSyncChange {
        let diffLeaves = PresenceWire.entries(from: payload[PresenceWire.leavesKey] ?? .object([:]))
        let diffJoins = PresenceWire.entries(from: payload[PresenceWire.joinsKey] ?? .object([:]))

        var joins: [String: [PresenceMeta]] = [:]
        var leaves: [String: [PresenceMeta]] = [:]

        // Leaves first (update normalization — see the type comment).
        for (key, leftMetas) in diffLeaves {
            guard var metas = entries[key] else { continue }
            let leavingRefs = Set(leftMetas.map(\.ref))
            let removed = metas.filter { leavingRefs.contains($0.ref) }
            guard !removed.isEmpty else { continue }
            metas.removeAll { leavingRefs.contains($0.ref) }
            if metas.isEmpty { entries.removeValue(forKey: key) } else { entries[key] = metas }
            let rejoinedRefs = Set((diffJoins[key] ?? []).map(\.ref))
            let net = removed.filter { !rejoinedRefs.contains($0.ref) }
            if !net.isEmpty { leaves[key] = net }
        }

        for (key, joinedMetas) in diffJoins {
            var metas = entries[key] ?? []
            var applied: [PresenceMeta] = []
            for meta in joinedMetas {
                if let index = metas.firstIndex(where: { $0.ref == meta.ref }) {
                    guard metas[index] != meta else { continue }
                    metas[index] = meta
                } else {
                    metas.append(meta)
                }
                applied.append(meta)
            }
            if !metas.isEmpty { entries[key] = metas }
            if !applied.isEmpty { joins[key] = applied }
        }

        return PresenceSyncChange(joins: joins, leaves: leaves)
    }
}
