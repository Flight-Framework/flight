import FlightChannelsProtocol
import struct Foundation.UUID
import Logging
import Synchronization

/// One client's WebSocket connection (§2): connection-level identity plus
/// the write side of that connection. A socket may hold many channels; its
/// lifetime is one `ConnectionUpgradeHandler` invocation, i.e. one request
/// `Scope` (Web §2, Core §3).
///
/// All writes funnel through one per-socket outbound queue drained by a
/// single writer task — channel handlers, PubSub fan-out pumps, and the
/// session's own replies never interleave partial frames and never block
/// each other on a slow client.
public final class Socket: Sendable, Identifiable {
    /// Unique per connection. Also the value `ChannelBroadcaster` stamps
    /// into origin metadata for `broadcast(..., excluding:)`.
    public let id: String

    /// The authenticated identity, established during the initial HTTP
    /// upgrade request (§5) — before the WebSocket existed. Nil when the
    /// endpoint accepts anonymous sockets.
    public let principal: (any ChannelPrincipal)?

    /// The connection's logger (request metadata already stamped by Flight
    /// Web's dispatch).
    public let logger: Logger

    private let outbound: AsyncStream<Envelope>.Continuation

    /// Topic-membership observation state (the framework seam below). All
    /// mutation happens under the mutex; observer callbacks always fire
    /// outside it.
    private struct TopicObservation {
        var closed = false
        var active: Set<String> = []
        var onActivated: [String: [@Sendable () -> Void]] = [:]
        var onTerminated: [String: [@Sendable () -> Void]] = [:]
    }

    private let observation = Mutex(TopicObservation())

    internal init(
        principal: (any ChannelPrincipal)?,
        logger: Logger,
        outbound: AsyncStream<Envelope>.Continuation
    ) {
        self.id = UUID().uuidString
        self.principal = principal
        self.logger = logger
        self.outbound = outbound
    }

    /// Pushes a server-initiated message to *this* socket only (`ref: null`,
    /// §4.1). For fan-out to every subscriber of a topic, use
    /// `ChannelBroadcaster` — a socket push is the "just this client" case
    /// (a private ack, a whisper).
    ///
    /// Fire-and-forget: enqueued onto the socket's outbound queue; if the
    /// connection is already closed the message is dropped, which
    /// at-most-once semantics (PubSub §8, inherited) already permit.
    public func push(topic: String, event: String, payload: JSONValue = .object([:])) {
        precondition(
            !event.hasPrefix(ReservedEvent.prefix),
            "'\(event)' is in the reserved flight: namespace (§4.2); application pushes must use their own event names."
        )
        outbound.yield(Envelope(ref: nil, topic: topic, event: event, payload: payload))
    }

    // MARK: - Framework seam (SPI)

    // The three members below exist for Flight's own packages layered on
    // Channels (Presence today, Live later) and are deliberately hidden
    // behind `@_spi(FlightInternal)`: application code sees none of this
    // unless it opts in with an SPI import, which keeps the reserved
    // `flight:` namespace and the membership lifecycle out of casual reach
    // while giving sibling framework packages the two seams they genuinely
    // need — pushing reserved events to one socket, and observing when this
    // socket's membership of a topic begins and ends.

    /// Pushes a *reserved* (`flight:`-namespaced) event to this socket —
    /// the framework counterpart of `push(topic:event:payload:)`, which
    /// enforces the opposite namespace rule. Fire-and-forget, same
    /// at-most-once semantics.
    @_spi(FlightInternal)
    public func pushReserved(topic: String, event: String, payload: JSONValue = .object([:])) {
        precondition(
            event.hasPrefix(ReservedEvent.prefix),
            "'\(event)' is not in the flight: namespace; use push(topic:event:payload:) for application events."
        )
        outbound.yield(Envelope(ref: nil, topic: topic, event: event, payload: payload))
    }

    /// Runs `perform` once this socket's membership of `topic` is fully
    /// established — the join accepted *and* its PubSub subscription pumping,
    /// so anything `perform` publishes or pushes is ordered after the join
    /// reply and no broadcast can fall between. Fires immediately if the
    /// membership is already active; dropped if the socket is already
    /// closed. One-shot: a later re-join does not re-fire it.
    @_spi(FlightInternal)
    public func onTopicActivated(_ topic: String, perform: @escaping @Sendable () -> Void) {
        let fireNow: Bool? = observation.withLock { state in
            if state.closed { return nil }
            if state.active.contains(topic) { return true }
            state.onActivated[topic, default: []].append(perform)
            return false
        }
        if fireNow == true { perform() }
    }

    /// Runs `perform` once when this socket's membership of `topic` ends —
    /// client leave, socket teardown on any path (transport drop, heartbeat
    /// timeout, server shutdown), whichever comes first. Fires immediately
    /// if the socket is already closed. One-shot; registration before the
    /// join is fine (it fires at socket close even if the join never
    /// happened, so cleanup registered optimistically can never leak).
    @_spi(FlightInternal)
    public func onTopicTerminated(_ topic: String, perform: @escaping @Sendable () -> Void) {
        let fireNow = observation.withLock { state in
            if state.closed { return true }
            state.onTerminated[topic, default: []].append(perform)
            return false
        }
        if fireNow { perform() }
    }

    // MARK: - Session internals

    internal func send(_ envelope: Envelope) {
        outbound.yield(envelope)
    }

    /// Called by `SocketSession` after a join is accepted and its PubSub
    /// pump is running.
    internal func notifyTopicActivated(_ topic: String) {
        let observers = observation.withLock { state -> [@Sendable () -> Void] in
            guard !state.closed else { return [] }
            state.active.insert(topic)
            return state.onActivated.removeValue(forKey: topic) ?? []
        }
        for observer in observers { observer() }
    }

    /// Called by `SocketSession` when a membership ends (leave or teardown).
    internal func notifyTopicTerminated(_ topic: String) {
        let observers = observation.withLock { state -> [@Sendable () -> Void] in
            state.active.remove(topic)
            state.onActivated.removeValue(forKey: topic)
            return state.onTerminated.removeValue(forKey: topic) ?? []
        }
        for observer in observers { observer() }
    }

    /// Called by `SocketSession.teardown` after every membership has been
    /// terminated: fires every still-pending termination observer (a
    /// registration whose topic was never joined, or whose join was
    /// rejected) so nothing registered against this socket can outlive it.
    internal func notifyClosed() {
        let observers = observation.withLock { state -> [@Sendable () -> Void] in
            state.closed = true
            state.active.removeAll()
            state.onActivated.removeAll()
            let pending = state.onTerminated.values.flatMap { $0 }
            state.onTerminated.removeAll()
            return pending
        }
        for observer in observers { observer() }
    }

    internal func sendReply(ref: String, topic: String, payload: JSONValue) {
        outbound.yield(Envelope(ref: ref, topic: topic, event: ReservedEvent.reply.rawValue, payload: payload))
    }

    internal func sendError(ref: String?, topic: String, reason: String) {
        outbound.yield(Envelope(
            ref: ref,
            topic: topic,
            event: ReservedEvent.error.rawValue,
            payload: .object([ChannelProtocol.errorReasonKey: .string(reason)])
        ))
    }
}
