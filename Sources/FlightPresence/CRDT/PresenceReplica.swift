/// Identifies one presence replica — one process's tracker (design §4).
///
/// Two parts, both load-bearing:
/// - `name` is the *node* identity: stable across restarts, configured (or
///   generated) per deployment, and the vocabulary failure detection speaks
///   (a membership monitor reports names, §5.1).
/// - `boot` is unique per process start. A restarted node is a *new
///   replica*: its counters restart from zero, and without a fresh boot id
///   its new dots would collide with the dots every other node already
///   observed from its previous life — silently swallowing its re-tracks.
///   The boot id makes restart safety structural instead of hopeful.
public struct PresenceReplicaID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let name: String
    public let boot: String

    public init(name: String, boot: String) {
        self.name = name
        self.boot = boot
    }

    public var description: String { "\(name)#\(boot)" }
}

/// One observed addition: `(replica, counter)` — the unit of add/remove in
/// the CRDT (§4). Counters are per-replica and monotonic within one boot.
public struct PresenceDot: Hashable, Sendable, Codable, Comparable {
    public let replica: PresenceReplicaID
    public let counter: UInt64

    public init(replica: PresenceReplicaID, counter: UInt64) {
        self.replica = replica
        self.counter = counter
    }

    /// A deterministic total order — the same on every node regardless of
    /// arrival order, so sorted views agree cluster-wide. Counter first:
    /// within one replica that is causal order, across replicas it is an
    /// arbitrary-but-stable tiebreak.
    public static func < (lhs: PresenceDot, rhs: PresenceDot) -> Bool {
        if lhs.counter != rhs.counter { return lhs.counter < rhs.counter }
        if lhs.replica.name != rhs.replica.name { return lhs.replica.name < rhs.replica.name }
        return lhs.replica.boot < rhs.replica.boot
    }
}
