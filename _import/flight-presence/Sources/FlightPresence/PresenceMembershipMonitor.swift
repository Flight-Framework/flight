/// A cluster node's liveness changed, as seen by a membership system.
/// `node` is the peer's stable node *name* — it must equal the peer's
/// `flight.presence.node-name`, which is also the `name` half of the
/// replica ids its gossip carries. One id vocabulary end to end, wired at
/// deployment; the adapter module that provides the monitor owns keeping
/// them aligned.
public enum PresenceMembershipEvent: Sendable, Equatable {
    case up(node: String)
    case down(node: String)
}

/// The membership seam: the thing a membership-aware PubSub
/// adapter module (the SWIM adapter, PubSub) registers so Presence
/// gets prompt, correct node-failure detection. When SWIM declares a node
/// dead, Presence removes every entry that node asserted, in one
/// operation, and pushes the resulting leave diffs.
///
/// Register a conformance as `(any PresenceMembershipMonitor).self` from
/// the adapter module's `configure`; `FlightPresenceModule` detects it at
/// freeze and runs in membership mode. Without one — the Valkey-style
/// fan-out-only adapter — Presence falls back to heartbeat-plus-expiry,
/// the documented degraded mode, and says so loudly at startup.
public protocol PresenceMembershipMonitor: Sendable {
    /// Membership transitions, from the monitor's start onward. Single
    /// consumer (the `PresenceService` run loop); nodes present before the
    /// stream starts need no synthetic `.up` — unknown names are presumed
    /// up until declared down.
    func events() -> AsyncStream<PresenceMembershipEvent>
}
