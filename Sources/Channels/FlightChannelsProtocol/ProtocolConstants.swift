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
}
