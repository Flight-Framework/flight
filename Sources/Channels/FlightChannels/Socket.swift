import FlightChannelsProtocol
import struct Foundation.UUID
import Logging
import Synchronization

/// One client's WebSocket connection: connection-level identity plus
/// the write side of that connection. A socket may hold many channels; its
/// lifetime is one `WebSocketUpgradeHandler` invocation, i.e. one request
/// `Scope` (Web, Core).
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
    /// upgrade request — before the WebSocket existed. Nil when the
    /// endpoint accepts anonymous sockets.
    public let principal: (any ChannelPrincipal)?

    /// The connection's logger (request metadata already stamped by Flight
    /// Web's dispatch).
    public let logger: Logger

    private let outbound: AsyncStream<String>.Continuation
    private let droppedEnvelopes = Atomic<Int64>(0)

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
        outbound: AsyncStream<String>.Continuation
    ) {
        self.id = UUID().uuidString
        self.principal = principal
        self.logger = logger
        self.outbound = outbound
    }

    /// Pushes a server-initiated message to *this* socket only (`ref: null`,
    ///). For fan-out to every subscriber of a topic, use
    /// `ChannelBroadcaster` — a socket push is the "just this client" case
    /// (a private ack, a whisper).
    ///
    /// Fire-and-forget: enqueued onto the socket's outbound queue; if the
    /// connection is already closed the message is dropped, which
    /// at-most-once semantics (PubSub, inherited) already permit.
    public func push(topic: String, event: String, payload: JSONValue = .object([:])) {
        // Rejected, not asserted. This used to be a `precondition`, which
        // terminates the process — every other connected socket with it —
        // because one caller passed a bad name.
        //
        // The framework filters `flight:`-prefixed events arriving from a
        // client before any handler sees them, so the envelope's own event
        // name cannot get here. An application deriving a name from client
        // *payload* can: `push(event: payload["type"])` is an ordinary
        // pattern, and a client sending `{"type": "flight:x"}` would have
        // taken the process down with it. Dropping the message and saying so
        // is the proportionate answer either way.
        guard !event.hasPrefix(ReservedEvent.prefix) else {
            logger.error(
                "refusing to push an event in the reserved flight: namespace",
                metadata: ["topic": "\(topic)", "event": "\(event)"]
            )
            return
        }
        enqueue(Envelope(ref: nil, topic: topic, event: event, payload: payload))
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
        guard event.hasPrefix(ReservedEvent.prefix) else {
            logger.error(
                "pushReserved called with a non-reserved event; use push(topic:event:payload:)",
                metadata: ["topic": "\(topic)", "event": "\(event)"]
            )
            return
        }
        enqueue(Envelope(ref: nil, topic: topic, event: event, payload: payload))
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
        enqueue(envelope)
    }

    /// Every outbound envelope goes through here, encoded exactly once
    /// (this is a single-target send — `push`/`sendReply`/`sendError` never
    /// had a redundant-encode problem the way topic fan-out did; see
    /// `SocketSession.pump` for where that redundancy actually lived and
    /// why the outbound queue carries pre-encoded text rather than
    /// `Envelope` values).
    ///
    /// The queue is bounded, so a client that stopped reading drops its
    /// oldest messages rather than growing without limit. `yield` says when
    /// that happened and the result used to be discarded at each call site —
    /// which meant a socket silently losing messages looked exactly like one
    /// that was fine.
    private func enqueue(_ envelope: Envelope) {
        guard let text = try? envelope.encodedText() else {
            logger.error("outbound envelope failed to encode", metadata: [
                "topic": "\(envelope.topic)", "event": "\(envelope.event)",
            ])
            return
        }
        switch outbound.yield(text) {
        case .enqueued, .terminated:
            break
        case .dropped:
            let total = droppedEnvelopes.wrappingAdd(1, ordering: .relaxed).oldValue + 1
            // Logged at intervals: a client stuck behind will drop steadily,
            // and a line per message would bury everything else.
            if total == 1 || total % 100 == 0 {
                logger.warning(
                    "outbound queue full; dropping the oldest messages for this socket",
                    metadata: [
                        "topic": "\(envelope.topic)",
                        "event": "\(envelope.event)",
                        "dropped-total": "\(total)",
                    ]
                )
            }
        @unknown default:
            break
        }
    }

    /// How many outbound envelopes this socket has dropped for being behind.
    public var droppedEnvelopeCount: Int {
        Int(droppedEnvelopes.load(ordering: .relaxed))
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
        enqueue(Envelope(ref: ref, topic: topic, event: ReservedEvent.reply.rawValue, payload: payload))
    }

    internal func sendError(ref: String?, topic: String, reason: String) {
        enqueue(Envelope(
            ref: ref,
            topic: topic,
            event: ReservedEvent.error.rawValue,
            payload: .object([ChannelProtocol.errorReasonKey: .string(reason)])
        ))
    }
}
