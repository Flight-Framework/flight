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
public struct PresenceCRDTState: Sendable, Equatable, Codable {
    public private(set) var context: DotContext
    public private(set) var entries: [PresenceDot: PresenceRecord]

    public init() {
        self.context = DotContext()
        self.entries = [:]
    }

    private init(context: DotContext, entries: [PresenceDot: PresenceRecord]) {
        self.context = context
        self.entries = entries
    }

    // MARK: - Local operations (each returns the delta to gossip)

    /// Adds one presence under a fresh dot. The caller owns counter
    /// allocation (monotonic per boot); `dot` must be unused.
    public mutating func add(_ record: PresenceRecord, at dot: PresenceDot) -> PresenceCRDTState {
        precondition(!context.contains(dot), "dot \(dot) reused — counters must be monotonic per boot")
        entries[dot] = record
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
        entries.removeValue(forKey: old)
        entries[dot] = record
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
    @discardableResult
    public mutating func join(_ incoming: PresenceCRDTState) -> PresenceStateChanges {
        var changes = PresenceStateChanges()
        for (dot, record) in incoming.entries where entries[dot] == nil && !context.contains(dot) {
            entries[dot] = record
            changes.added.append((dot, record))
        }
        for (dot, record) in entries where incoming.entries[dot] == nil && incoming.context.contains(dot) {
            entries.removeValue(forKey: dot)
            changes.removed.append((dot, record))
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
        let own = entries.filter { $0.key.replica == replica }
        return PresenceCRDTState(context: deltaContext, entries: own)
    }

    /// Removes everything a replica asserted, and forgets its context —
    /// the permdown purge. Not a CRDT operation: every node applies
    /// it independently on the same failure evidence. Safe because boot
    /// ids never recur (see `PresenceReplicaID`).
    @discardableResult
    public mutating func evict(_ replica: PresenceReplicaID) -> [(PresenceDot, PresenceRecord)] {
        let evicted = entries.filter { $0.key.replica == replica }
        for dot in evicted.keys { entries.removeValue(forKey: dot) }
        context.forget(replica)
        return Array(evicted)
    }

    // MARK: - Views

    /// All live dots asserted by `replica`.
    public func dots(of replica: PresenceReplicaID) -> [PresenceDot] {
        entries.keys.filter { $0.replica == replica }
    }
}
