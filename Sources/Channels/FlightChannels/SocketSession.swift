import FlightChannelsProtocol
import FlightPubSub
import FlightWeb
import Logging

/// Per-socket protocol state: which topics are joined, which `Channel`
/// instance and PubSub pump each holds, and liveness. An actor because
/// joins, leaves, inbound events, the watchdog, and teardown all touch this
/// state from different tasks; envelope *processing* is serialized per
/// socket by the frame loop itself (one message fully handled before the
/// next is read — the ordering a stateful protocol wants).
internal actor SocketSession {

    /// What the frame loop should do after one envelope is handled.
    internal enum Directive: Sendable, Equatable {
        case proceed
        /// Stop the session and close the transport with this code. Replies
        /// already enqueued are flushed first (the writer drains the
        /// outbound queue before the close frame goes out).
        case close(code: WebSocketCloseCode, reason: String)
    }

    private struct JoinedChannel {
        let channel: any Channel
        let pump: Task<Void, Never>
    }

    private let router: ChannelRouter
    private let pubsub: any PubSub
    private let socket: Socket
    private let outbound: AsyncStream<String>.Continuation
    private let logger: Logger

    private var joined: [String: JoinedChannel] = [:]
    private var lastActivity = ContinuousClock.now
    private var isTornDown = false

    internal init(
        router: ChannelRouter,
        pubsub: any PubSub,
        socket: Socket,
        outbound: AsyncStream<String>.Continuation,
        logger: Logger
    ) {
        self.router = router
        self.pubsub = pubsub
        self.socket = socket
        self.outbound = outbound
        self.logger = logger
    }

    // MARK: - Liveness

    internal func touch() {
        lastActivity = .now
    }

    internal var idleDuration: Duration {
        ContinuousClock.now - lastActivity
    }

    // MARK: - Inbound routing

    internal func handle(_ envelope: Envelope) async -> Directive {
        guard !isTornDown else { return .proceed }

        switch ReservedEvent(rawValue: envelope.event) {
        case .join:
            await join(envelope)
        case .leave:
            await leave(envelope)
        case .heartbeat:
            heartbeat(envelope)
        case .close:
            // Graceful client-initiated teardown. The ack must be
            // enqueued BEFORE teardown — teardown finishes the outbound
            // queue, and the writer flushes only what was queued first.
            if let ref = envelope.ref {
                socket.sendReply(ref: ref, topic: envelope.topic, payload: .object([:]))
            }
            await teardown()
            return .close(code: .normalClosure, reason: "client close")
        case .reply, .error:
            // Server-to-client events; a client never sends them.
            socket.sendError(ref: envelope.ref, topic: envelope.topic, reason: ChannelErrorReason.invalidEvent)
        case nil where envelope.event.hasPrefix(ReservedEvent.prefix):
            // flight:-namespaced but not a reserved event we know. Because
            // Flight versions protocol and clients together, this is a
            // client bug — named as such, connection kept.
            socket.sendError(ref: envelope.ref, topic: envelope.topic, reason: ChannelErrorReason.invalidEvent)
        case nil:
            await dispatchApplicationEvent(envelope)
        }
        return .proceed
    }

    // MARK: - Join (the join is the gate)

    private func join(_ envelope: Envelope) async {
        let topic = envelope.topic
        guard topic != ChannelProtocol.controlTopic else {
            socket.sendError(ref: envelope.ref, topic: topic, reason: ChannelErrorReason.reservedTopic)
            return
        }
        guard joined[topic] == nil else {
            socket.sendError(ref: envelope.ref, topic: topic, reason: ChannelErrorReason.alreadyJoined)
            return
        }
        guard let registration = router.match(topic) else {
            socket.sendError(ref: envelope.ref, topic: topic, reason: ChannelErrorReason.unmatchedTopic)
            return
        }

        let channel: any Channel
        do {
            channel = try registration.makeChannel()
        } catch {
            logger.error("channel factory failed", metadata: [
                "topic": "\(topic)", "source": "\(registration.source)", "error": "\(error)",
            ])
            socket.sendError(ref: envelope.ref, topic: topic, reason: ChannelErrorReason.handlerError)
            return
        }

        switch (await channel.join(topic, socket: socket)).outcome {
        case .rejected(let rejection):
            socket.sendError(ref: envelope.ref, topic: topic, reason: rejection.reason)

        case .accepted(let initialState):
            // Order is load-bearing (PubSub's "effective when
            // subscribe returns"): subscribe first so no broadcast between
            // admission and pump start is lost; enqueue the join reply
            // second; start the pump last. Everything funnels through one
            // outbound queue, so the client always sees the join reply
            // before any broadcast.
            let subscription = pubsub.subscribe(topic)
            if let ref = envelope.ref {
                socket.sendReply(ref: ref, topic: topic, payload: initialState ?? .null)
            }
            let pump = Task {
                await Self.pump(
                    subscription: subscription,
                    topic: topic,
                    socketID: self.socket.id,
                    outbound: self.outbound,
                    logger: self.logger
                )
            }
            joined[topic] = JoinedChannel(channel: channel, pump: pump)
            // Membership is fully established (pump subscribed): let
            // framework observers (Presence's state push) run, ordered
            // after the join reply and never ahead of the subscription.
            socket.notifyTopicActivated(topic)
        }
    }

    /// One channel's fan-in: iterate the PubSub stream and enqueue each
    /// broadcast for this socket. `nonisolated` so per-message delivery
    /// never hops through the session actor.
    ///
    /// The common case (a `ChannelBroadcaster` publish) carries its final
    /// wire text precomputed in metadata — every subscriber's `Envelope` for
    /// one broadcast is byte-identical, so `publish` builds it once and
    /// every pump here just forwards the same `String` by reference: no
    /// decode, no per-subscriber re-encode. A message with no such key (a
    /// hand-built `BroadcastFrame`, e.g. Presence) falls back to decoding
    /// and encoding it directly — slower, but correct, and unchanged from
    /// before this fast path existed.
    private nonisolated static func pump(
        subscription: AsyncStream<Message>,
        topic: String,
        socketID: String,
        outbound: AsyncStream<String>.Continuation,
        logger: Logger
    ) async {
        for await message in subscription {
            if message.metadata[ChannelBroadcaster.originMetadataKey] == socketID {
                continue // broadcast(..., excluding:) — this socket is the origin
            }
            if let precomputed = message.metadata[ChannelBroadcaster.precomputedFrameMetadataKey] {
                outbound.yield(precomputed)
                continue
            }
            guard let frame = BroadcastFrame(message: message) else {
                logger.warning("dropping non-broadcast payload on channel topic", metadata: [
                    "topic": "\(topic)",
                ])
                continue
            }
            guard
                let text = try? Envelope(ref: nil, topic: topic, event: frame.event, payload: frame.payload)
                    .encodedText()
            else {
                logger.warning("broadcast envelope failed to encode", metadata: ["topic": "\(topic)"])
                continue
            }
            outbound.yield(text)
        }
    }

    // MARK: - Leave

    private func leave(_ envelope: Envelope) async {
        guard let entry = joined.removeValue(forKey: envelope.topic) else {
            socket.sendError(ref: envelope.ref, topic: envelope.topic, reason: ChannelErrorReason.notJoined)
            return
        }
        entry.pump.cancel()
        await entry.channel.leave(envelope.topic, socket: socket)
        socket.notifyTopicTerminated(envelope.topic)
        if let ref = envelope.ref {
            socket.sendReply(ref: ref, topic: envelope.topic, payload: .object([:]))
        }
    }

    // MARK: - Heartbeat

    private func heartbeat(_ envelope: Envelope) {
        // touch() already ran in the frame loop; just ack.
        if let ref = envelope.ref {
            socket.sendReply(ref: ref, topic: ChannelProtocol.controlTopic, payload: .object([:]))
        }
    }

    // MARK: - Application events

    private func dispatchApplicationEvent(_ envelope: Envelope) async {
        guard let entry = joined[envelope.topic] else {
            socket.sendError(ref: envelope.ref, topic: envelope.topic, reason: ChannelErrorReason.notJoined)
            return
        }
        let event = InboundEvent(
            topic: envelope.topic,
            event: envelope.event,
            payload: envelope.payload,
            ref: envelope.ref
        )
        switch (await entry.channel.handle(event, socket: socket)).outcome {
        case .none:
            break
        case .reply(let payload):
            if let ref = envelope.ref {
                socket.sendReply(ref: ref, topic: envelope.topic, payload: payload)
            }
        case .error(let reason):
            socket.sendError(ref: envelope.ref, topic: envelope.topic, reason: reason)
        }
    }

    // MARK: - Teardown (structured, no manual cleanup)

    /// Leaves every channel (handler `leave` runs, PubSub pumps end) and
    /// finishes the outbound queue so the writer drains and exits.
    /// Idempotent — every exit path (peer close, `flight:close`, protocol
    /// violation, heartbeat timeout, server shutdown) funnels here once.
    internal func teardown() async {
        guard !isTornDown else { return }
        isTornDown = true
        let entries = joined
        joined = [:]
        for (topic, entry) in entries {
            entry.pump.cancel()
            await entry.channel.leave(topic, socket: socket)
            socket.notifyTopicTerminated(topic)
        }
        socket.notifyClosed()
        outbound.finish()
    }

    // MARK: - Introspection (tests, diagnostics)

    internal var joinedTopics: Set<String> {
        Set(joined.keys)
    }
}
