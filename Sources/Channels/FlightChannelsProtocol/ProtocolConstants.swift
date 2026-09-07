/// The reserved lifecycle events: a small fixed set, namespaced
/// `flight:` so they never collide with application events. Everything else
/// on the wire is an application event, passed to the `Channel`'s `handle`.
public enum ReservedEvent: String, Sendable, CaseIterable {
    /// Topic membership.
    case join = "flight:join"
    case leave = "flight:leave"
    /// A successful reply to a client message carrying a `ref`.
    case reply = "flight:reply"
    /// A channel-level error — join rejected, handler error. Carries
    /// the originating `ref` when it answers a correlated message, so a
    /// client's pending push can reject; `ref: null` when uncorrelated.
    case error = "flight:error"
    /// Keepalive, sent by the client on the control topic.
    case heartbeat = "flight:heartbeat"
    /// Graceful channel/socket teardown.
    case close = "flight:close"

    /// The namespace prefix. A client-sent application event may never start
    /// with this; the server answers such an event with `flight:error`.
    public static let prefix = "flight:"
}

/// Protocol-level names and values shared by server and clients.
public enum ChannelProtocol {
    /// The topic socket-level control events (`flight:heartbeat`,
    /// `flight:close`) travel on. Reserved: it can never be joined.
    public static let controlTopic = "flight"

    /// The `flight:error` payload is `{"reason": <string>}`; this is its key.
    public static let errorReasonKey = "reason"

    /// The prefix under which channel traffic travels on the PubSub bus.
    ///
    /// Frames a channel fans out are *not* published on the topic a client
    /// joined; they are published under this prefix. Presence has always
    /// namespaced its gossip (`flight:presence`), and channel traffic now
    /// does the same.
    public static let busPrefix = "flight:channels:"

    /// The bus topic a channel topic's frames travel on.
    ///
    /// Channels' fan-out is PubSub's, and it used to publish straight onto
    /// the application's own topic string — one namespace for two unrelated
    /// things. Both directions of that collision were real: an application
    /// subscribing to `shipment:42` received Channels' internal frames as
    /// opaque JSON, and an application *publishing* to `shipment:42` had its
    /// message dropped by every connected socket's pump, with a warning
    /// each. Neither was documented, and both are easy to hit — a topic name
    /// like "the thing this is about" is the obvious choice on both sides.
    ///
    /// The mapping is a prefix, so it is injective: two distinct channel
    /// topics never share a bus topic. Nothing on the wire changes — this
    /// names a topic on the bus, never one a client joins or sees.
    ///
    /// Code that deliberately watches channel traffic from outside Channels
    /// subscribes through this:
    ///
    /// ```swift
    /// for await message in pubsub.subscribe(ChannelProtocol.busTopic("room:42")) { … }
    /// ```
    public static func busTopic(_ topic: String) -> String { busPrefix + topic }
}

/// Error reasons the server emits in `flight:error` payloads. Strings, not
/// an enum, on the wire — but every reason the server itself produces is
/// named here so clients and tests share one vocabulary.
public enum ChannelErrorReason {
    /// Join refused: no authenticated principal.
    public static let unauthenticated = "unauthenticated"
    /// Join refused: authenticated but not allowed.
    public static let forbidden = "forbidden"
    /// Join refused: no registered channel serves this topic.
    public static let unmatchedTopic = "unmatched_topic"
    /// Join refused: this socket already holds this topic's channel.
    public static let alreadyJoined = "already_joined"
    /// Message on a topic this socket has not joined.
    public static let notJoined = "not_joined"
    /// Join refused: the control topic (`ChannelProtocol.controlTopic`)
    /// cannot be joined.
    public static let reservedTopic = "reserved_topic"
    /// The channel handler failed (threw from its factory, or reported an
    /// unnameable error). Detail goes to the server log, never the wire.
    public static let handlerError = "handler_error"
    /// A client-sent event was `flight:`-namespaced but is not one a client
    /// may send (`flight:reply`, `flight:error`, unknown `flight:*`).
    public static let invalidEvent = "invalid_event"
}

/// WebSocket close codes Flight Channels uses beyond the RFC 6455 standard
/// set — 4000-range, the RFC's private-use space.
public enum ChannelCloseCode {
    /// The socket went silent past the heartbeat timeout.
    public static let heartbeatTimeout: UInt16 = 4000
    /// A frame violated the protocol: undecodable envelope. Because
    /// Flight owns both clients, this is always a bug or an attack — the
    /// server closes rather than negotiating.
    public static let protocolViolation: UInt16 = 4400

    /// The peer stopped reading: one outbound frame took longer than
    /// `flight.channels.write-timeout-seconds` to leave.
    ///
    /// Distinct from ``heartbeatTimeout`` because the two say different
    /// things about the same client — one has gone silent, the other is
    /// still talking but no longer listening — and distinct from a normal
    /// closure because it is not one. It used to be reported as `1000`,
    /// which a client cannot tell from a clean server shutdown, so a
    /// reconnect loop treated "you are not reading" as "come back".
    public static let writeTimeout: UInt16 = 4408
}
