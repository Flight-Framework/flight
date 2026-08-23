import FlightChannelsProtocol

/// Per-topic server logic: joining a topic creates one instance of the
/// registered `Channel` for that (socket, topic) pair, so implementations
/// may keep per-membership state in stored properties.
public protocol Channel: Sendable {
    /// Called when a client attempts to join this channel's topic. Return
    /// `.ok` to admit (optionally with initial state to send back), or
    /// `.reject` to deny — this is the authorization point.
    func join(_ topic: String, socket: Socket) async -> JoinResult

    /// A message arrived FROM this client on this channel.
    func handle(_ event: InboundEvent, socket: Socket) async -> HandleResult

    /// Optional: called when the client leaves or the socket closes.
    func leave(_ topic: String, socket: Socket) async
}

extension Channel {
    public func leave(_ topic: String, socket: Socket) async {}
}

/// Why a join was refused. The `reason` string travels to the client in the
/// `flight:error` payload — keep it wire-safe.
public struct JoinRejection: Sendable, Equatable {
    public let reason: String

    public init(_ reason: String) {
        self.reason = reason
    }

    public static let unauthenticated = JoinRejection(ChannelErrorReason.unauthenticated)
    public static let forbidden = JoinRejection(ChannelErrorReason.forbidden)
}

/// The outcome of `Channel.join`.
///
///     return .ok
///     return .ok(initialState: currentRoomState())
///     return .reject(.forbidden)
public struct JoinResult: Sendable {
    internal enum Outcome: Sendable {
        case accepted(initialState: JSONValue?)
        case rejected(JoinRejection)
    }

    internal let outcome: Outcome

    /// Admit, with no initial state (the join reply's payload is `null`).
    public static let ok = JoinResult(outcome: .accepted(initialState: nil))

    /// Admit, sending `initialState` back as the join reply's payload.
    public static func ok(initialState: JSONValue) -> JoinResult {
        JoinResult(outcome: .accepted(initialState: initialState))
    }

    public static func reject(_ rejection: JoinRejection) -> JoinResult {
        JoinResult(outcome: .rejected(rejection))
    }
}

/// One application event from the client, as `Channel.handle` receives it.
/// `topic` is included because one `Channel` registration may serve a
/// wildcard pattern (`"room:*"`) — the instance knows which topic it holds.
public struct InboundEvent: Sendable, Equatable {
    public let topic: String
    public let event: String
    public let payload: JSONValue
    /// Present when the client wants a reply.
    public let ref: String?

    public init(topic: String, event: String, payload: JSONValue, ref: String?) {
        self.topic = topic
        self.event = event
        self.payload = payload
        self.ref = ref
    }
}

/// The outcome of `Channel.handle`: reply to a ref-carrying message,
/// report an error, or say nothing.
///
/// `.none` on a ref-carrying message sends no reply — the client's awaited
/// push times out on its side. That mirrors Phoenix's `:noreply`: whether a
/// given event replies is part of the channel's contract with its client,
/// not something the transport paper over.
public struct HandleResult: Sendable {
    internal enum Outcome: Sendable {
        case none
        case reply(JSONValue)
        case error(reason: String)
    }

    internal let outcome: Outcome

    /// No reply. Broadcast side effects have already happened in `handle`.
    public static let none = HandleResult(outcome: .none)

    /// Send a `flight:reply` echoing the inbound `ref`. Dropped if
    /// the inbound message carried no ref — there is nothing to correlate.
    public static func reply(_ payload: JSONValue) -> HandleResult {
        HandleResult(outcome: .reply(payload))
    }

    /// Send a `flight:error` (with the inbound `ref`, when present) carrying
    /// `{"reason": reason}`. Keep the reason wire-safe; detail belongs in
    /// the server log.
    public static func error(reason: String) -> HandleResult {
        HandleResult(outcome: .error(reason: reason))
    }
}
