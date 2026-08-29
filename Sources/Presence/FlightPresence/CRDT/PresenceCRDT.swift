/// What one dot asserts: this connection, on this topic, under this key,
/// with this meta. The `ref` is the client-visible meta identity and
/// survives updates; the dot is the CRDT-internal identity and does not.
public struct PresenceRecord: Sendable, Equatable, Codable {
    public let topic: String
    public let key: String
    public let ref: String
    public let payload: [String: String]

    public init(topic: String, key: String, ref: String, payload: [String: String]) {
        self.topic = topic
        self.key = key
        self.ref = ref
        self.payload = payload
    }
}

/// What applying a state changed — the tracker turns this into client
/// diffs. Order within each list is not meaningful.
public struct PresenceStateChanges: Sendable {
    public var added: [(PresenceDot, PresenceRecord)] = []
    public var removed: [(PresenceDot, PresenceRecord)] = []

    public var isEmpty: Bool { added.isEmpty && removed.isEmpty }
}

/// The replicated presence state: an observed-remove set
/// without tombstones (ORSWOT), the same construction Phoenix Presence
/// uses, in its delta-state form. One type serves as both a replica's full
/// state and every gossip payload — an add, a remove, an update, and a
/// full snapshot are all just small states, and `join` is the only merge
/// operation anywhere.
///
/// `join` is commutative, associative, and idempotent, so duplicated or
/// reordered gossip is harmless and any two replicas that have seen the
/// same set of deltas agree — the property the convergence suite asserts
/// wholesale rather than by example.
public struct PresenceCRDTState: Sendable {
    public private(set) var context: DotContext
    public private(set) var entries: [PresenceDot: PresenceRecord]

    /// `entries` grouped by asserting replica.
    ///
    /// The sibling of `PresenceTracker`'s `topicIndex`, and for the same
    /// reason. Every operation that used to ask "which of my entries belong
    /// to this replica" answered it by scanning the whole cluster-wide map:
    /// the join's removal pass on every gossip frame (with N peers
    /// snapshotting every 5s, O(N·E) per interval on the actor that also
    /// serializes every client diff), plus `snapshot` on every heartbeat,
    /// `evict`, and `dots(of:)`.
    private var byReplica: [PresenceReplicaID: Set<PresenceDot>]

    public init() {
        self.context = DotContext()
        self.entries = [:]
        self.byReplica = [:]
    }

    private init(context: DotContext, entries: [PresenceDot: PresenceRecord]) {
        self.context = context
        self.entries = entries
        self.byReplica = [:]
        for dot in entries.keys { byReplica[dot.replica, default: []].insert(dot) }
    }

    private mutating func index(_ dot: PresenceDot) {
        byReplica[dot.replica, default: []].insert(dot)
    }

    private mutating func unindex(_ dot: PresenceDot) {
        byReplica[dot.replica]?.remove(dot)
        if byReplica[dot.replica]?.isEmpty == true { byReplica.removeValue(forKey: dot.replica) }
    }

    /// Forges a context claim about another replica — the malformed or
    /// hostile frame ``join(_:ownReplica:)`` exists to refuse. Tests only;
    /// nothing in the library can produce one.
    mutating func forgeClaimForTesting(about replica: PresenceReplicaID, through counter: UInt64) {
        context.extend(replica, through: counter)
    }

    /// Refuses a peer's claim to have observed dots `replica` asserted.
    /// See ``join(_:ownReplica:)``.
    mutating func dropClaims(about replica: PresenceReplicaID) {
        context.dropClaims(about: replica)
        for dot in entries.keys where dot.replica == replica {
            entries.removeValue(forKey: dot)
            unindex(dot)
        }
    }

    // MARK: - Local operations (each returns the delta to gossip)

    /// Adds one presence under a fresh dot. The caller owns counter
    /// allocation (monotonic per boot); `dot` must be unused.
    public mutating func add(_ record: PresenceRecord, at dot: PresenceDot) -> PresenceCRDTState {
        precondition(!context.contains(dot), "dot \(dot) reused — counters must be monotonic per boot")
        entries[dot] = record
        index(dot)
        context.insert(dot)
        var deltaContext = DotContext()
        deltaContext.insert(dot)
        return PresenceCRDTState(context: deltaContext, entries: [dot: record])
    }

    /// Removes the given observed dots (a local untrack — only ever this
    /// replica's own dots in practice). The delta carries the removed dots
    /// in its context and no entries: joining it elsewhere removes exactly
    /// those observed additions, never a concurrent add.
    public mutating func remove(_ dots: some Sequence<PresenceDot>) -> PresenceCRDTState {
        var deltaContext = DotContext()
        for dot in dots where entries.removeValue(forKey: dot) != nil {
            unindex(dot)
            deltaContext.insert(dot)
        }
        return PresenceCRDTState(context: deltaContext, entries: [:])
    }

    /// A meta update in place: a fresh dot for the new payload, the
    /// old dot removed, one delta carrying both — so remotely it applies
    /// as the same atomic replacement it was locally.
    public mutating func replace(
        _ old: PresenceDot,
        with record: PresenceRecord,
        at dot: PresenceDot
    ) -> PresenceCRDTState {
        precondition(!context.contains(dot), "dot \(dot) reused — counters must be monotonic per boot")
        if entries.removeValue(forKey: old) != nil { unindex(old) }
        entries[dot] = record
        index(dot)
        context.insert(dot)
        var deltaContext = DotContext()
        deltaContext.insert(old)
        deltaContext.insert(dot)
        return PresenceCRDTState(context: deltaContext, entries: [dot: record])
    }

    // MARK: - Merge

    /// The one merge operation. Standard optimized-ORSet join:
    /// - an entry we don't hold is added unless our context already
    ///   observed its dot (then it was removed here — stays removed);
    /// - an entry we hold is removed if the incoming state observed its
    ///   dot but no longer holds it (a remove we hadn't seen);
    /// - contexts union.
    /// - Parameter ownReplica: This node's replica id, when the state being
    ///   joined came from the wire. A peer may not speak about dots this
    ///   replica asserted — only a replica ever asserts its own — and
    ///   merging such a claim raised our version past our clock, so the next
    ///   local `track` tripped `add`'s precondition and killed the process:
    ///   a one-frame remote crash, not merely state corruption. Pass nil for
    ///   a locally-produced delta, where there is nothing to distrust.
    @discardableResult
    public mutating func join(
        _ incoming: PresenceCRDTState, ownReplica: PresenceReplicaID? = nil
    ) -> PresenceStateChanges {
        var incoming = incoming
        if let ownReplica {
            incoming.dropClaims(about: ownReplica)
        }
        var changes = PresenceStateChanges()
        for (dot, record) in incoming.entries where entries[dot] == nil && !context.contains(dot) {
            entries[dot] = record
            index(dot)
            changes.added.append((dot, record))
        }
        // Only the replicas the incoming context speaks about can have had
        // anything removed — a frame's context covers its sender and nobody
        // else — so this walks those replicas' entries rather than every
        // entry in the cluster.
        for replica in incoming.context.replicas {
            for dot in byReplica[replica] ?? [] {
                guard incoming.entries[dot] == nil, incoming.context.contains(dot) else { continue }
                guard let record = entries.removeValue(forKey: dot) else { continue }
                unindex(dot)
                changes.removed.append((dot, record))
            }
        }
        context.merge(incoming.context)
        return changes
    }

    // MARK: - Anti-entropy

    /// This replica's authoritative statement about its own presences: all
    /// of its live entries, plus a context claiming its whole counter
    /// range `1...clock`. Joining it repairs any lost delta from this
    /// replica — a missed add appears, a missed remove disappears — and
    /// touches nothing another replica asserted. The periodic re-announce
    /// (heartbeats; anti-entropy in membership mode) gossips exactly
    /// this.
    public func snapshot(of replica: PresenceReplicaID, clock: UInt64) -> PresenceCRDTState {
        var deltaContext = DotContext()
        deltaContext.extend(replica, through: clock)
        var own: [PresenceDot: PresenceRecord] = [:]
        for dot in byReplica[replica] ?? [] { own[dot] = entries[dot] }
        return PresenceCRDTState(context: deltaContext, entries: own)
    }

    /// Removes everything a replica asserted, and forgets its context —
    /// the permdown purge. Not a CRDT operation: every node applies
    /// it independently on the same failure evidence. Safe because boot
    /// ids never recur (see `PresenceReplicaID`).
    @discardableResult
    public mutating func evict(_ replica: PresenceReplicaID) -> [(PresenceDot, PresenceRecord)] {
        var evicted: [(PresenceDot, PresenceRecord)] = []
        for dot in byReplica.removeValue(forKey: replica) ?? [] {
            if let record = entries.removeValue(forKey: dot) { evicted.append((dot, record)) }
        }
        context.forget(replica)
        return evicted
    }

    // MARK: - Views

    /// All live dots asserted by `replica`.
    public func dots(of replica: PresenceReplicaID) -> [PresenceDot] {
        Array(byReplica[replica] ?? [])
    }
}

// MARK: - Wire form

/// Hand-written rather than synthesized, because `byReplica` is a derived
/// index and must not reach the wire: this one type is both a replica's local
/// state and every gossip payload, so a stored property added for the local
/// side would silently change the protocol. It is rebuilt on decode.
extension PresenceCRDTState: Codable {
    private enum CodingKeys: String, CodingKey { case context, entries }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            context: try container.decode(DotContext.self, forKey: .context),
            entries: try container.decode([PresenceDot: PresenceRecord].self, forKey: .entries)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(context, forKey: .context)
        try container.encode(entries, forKey: .entries)
    }
}

/// Equal when the state is equal. `byReplica` is derived from `entries`, so
/// comparing it would be redundant at best and, if it ever drifted, would
/// hide the drift behind an inequality nobody could explain.
extension PresenceCRDTState: Equatable {
    public static func == (lhs: PresenceCRDTState, rhs: PresenceCRDTState) -> Bool {
        lhs.context == rhs.context && lhs.entries == rhs.entries
    }
}
