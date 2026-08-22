/// The set of dots a state has *observed* — present or since removed
/// (design §4: "tracks which additions it has observed"). This is what
/// makes removal safe without tombstones: an entry is live iff its dot is
/// in `entries`; a dot in the context but not in `entries` was observed
/// and removed, so a stale re-delivery of its add can never resurrect it.
///
/// Representation: a version vector of *contiguous* observed prefixes
/// (`versions[r] = n` ⇒ dots `(r, 1...n)` all observed) plus a cloud of
/// out-of-order dots awaiting compaction. Every mutation compacts, so the
/// cloud stays small — it only holds gaps from reordered gossip.
public struct DotContext: Sendable, Equatable, Codable {
    public private(set) var versions: [PresenceReplicaID: UInt64]
    public private(set) var cloud: Set<PresenceDot>

    public init() {
        self.versions = [:]
        self.cloud = []
    }

    public func contains(_ dot: PresenceDot) -> Bool {
        dot.counter <= versions[dot.replica, default: 0] || cloud.contains(dot)
    }

    /// Observe one dot.
    public mutating func insert(_ dot: PresenceDot) {
        guard !contains(dot) else { return }
        cloud.insert(dot)
        compact(dot.replica)
    }

    /// Observe the whole contiguous prefix `(replica, 1...counter)` — the
    /// claim only `replica` itself can make, and exactly what its snapshot
    /// carries (§4 / tracker anti-entropy): "everything I have ever added
    /// up to `counter` is either in this snapshot's entries or removed."
    public mutating func extend(_ replica: PresenceReplicaID, through counter: UInt64) {
        versions[replica] = max(versions[replica, default: 0], counter)
        compact(replica)
    }

    /// Union of observations. Pointwise max is sound because a version
    /// entry is only ever a genuinely-contiguous claim (built by
    /// compaction from 1, or asserted by the owning replica via `extend`);
    /// the max of two contiguous prefixes is contiguous.
    public mutating func merge(_ other: DotContext) {
        for (replica, counter) in other.versions {
            versions[replica] = max(versions[replica, default: 0], counter)
        }
        let replicas = Set(other.cloud.map(\.replica))
        cloud.formUnion(other.cloud)
        for replica in replicas { compact(replica) }
        // A raised version may also have absorbed our own cloud dots.
        for replica in Set(cloud.map(\.replica)) { compact(replica) }
    }

    /// Forget a replica entirely — the permdown purge (§5). Only safe
    /// because a purged replica never returns: its boot id is unique per
    /// process, so no future dot can collide with a forgotten one.
    public mutating func forget(_ replica: PresenceReplicaID) {
        versions.removeValue(forKey: replica)
        cloud = cloud.filter { $0.replica != replica }
    }

    private mutating func compact(_ replica: PresenceReplicaID) {
        var version = versions[replica, default: 0]
        while cloud.contains(PresenceDot(replica: replica, counter: version + 1)) {
            version += 1
            cloud.remove(PresenceDot(replica: replica, counter: version))
        }
        cloud = cloud.filter { $0.replica != replica || $0.counter > version }
        if version > 0 { versions[replica] = version }
    }
}
