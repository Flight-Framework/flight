@_spi(FlightInternal) import FlightChannels
import FlightPresenceProtocol

/// The application-facing surface (design §3). Resolve `(any Presence)`
/// from the container; call it from channel handlers:
///
///     struct RoomChannel: Channel {
///         let presence: any Presence
///
///         func join(_ topic: String, socket: Socket) async -> JoinResult {
///             guard let user = socket.principal?.subject else {
///                 return .reject(.unauthenticated)
///             }
///             await presence.track(topic: topic, key: user, payload: [:], socket: socket)
///             await presence.sendState(topic: topic, to: socket)
///             return .ok
///         }
///     }
///
/// A node's own connections are the only thing it observes directly;
/// everything else it knows is what other nodes have told it (§4).
public protocol Presence: Sendable {
    /// Register a presence for the life of a connection's membership of
    /// `topic`. Untracking is automatic and structural (§7): when the
    /// membership ends — client leave, or the socket closing on any path —
    /// the metas are removed and the leave diff broadcast. No manual
    /// cleanup.
    ///
    /// One meta per call per (connection, topic, key); calling again for
    /// the same triple replaces that meta in place (update semantics).
    /// `"ref"` is a reserved payload key and is dropped if supplied.
    func track(topic: String, key: String, payload: [String: String], socket: Socket) async

    /// Update an existing meta in place (e.g. status changed to "away").
    /// The meta keeps its `ref`; on the wire the change travels as a leave
    /// of the old meta plus a join of the new one for that same ref, which
    /// the client helpers normalize back into an update (§6). A no-op with
    /// a warning log when nothing is tracked for the triple.
    func update(topic: String, key: String, payload: [String: String], socket: Socket) async

    /// Explicitly remove one tracked meta before the membership ends.
    /// Rarely needed — cleanup is automatic (§7) — but "stop appearing
    /// present, stay in the room" is a legitimate application choice.
    func untrack(topic: String, key: String, socket: Socket) async

    /// Push the full current presence list for `topic` to one socket as a
    /// `flight:presence_state` message (§6). Call it alongside `track` in
    /// the channel's `join` (or alone, for a watch-only member): delivery
    /// waits for the membership to be fully established, so the client
    /// sees join-reply, then state, then diffs — no gap a change could
    /// fall through.
    func sendState(topic: String, to socket: Socket) async

    /// Current merged view of a topic: local + all known remote nodes,
    /// excluding nodes currently considered down (§5). Sorted by key.
    func list(topic: String) async -> [PresenceEntry]
}
