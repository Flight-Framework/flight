import FlightChannelsProtocol

/// A client's view of one topic on its socket — the client-side half of the
/// design's `Channel` noun (§2). Thin value façade over `ChannelClient`;
/// create as many as you like via `client.channel(_:)`.
public struct ChannelHandle: Sendable {
    public let topic: String
    private let client: ChannelClient

    internal init(topic: String, client: ChannelClient) {
        self.topic = topic
        self.client = client
    }

    /// Joins the topic (§5: the join is the gate). Returns the channel's
    /// initial state (`.null` when the server sent none). Throws
    /// `.channelError(reason:)` when the join is rejected.
    ///
    /// Membership survives reconnection: after a drop, the client rejoins
    /// automatically and the fresh initial state arrives on `messages()`
    /// as a `flight:join` message (`ChannelMessage.isRejoin`).
    @discardableResult
    public func join(timeout: Duration? = nil) async throws -> JSONValue {
        try await client.join(topic: topic, timeout: timeout)
    }

    /// Leaves the topic; the server runs the channel's `leave` and ends its
    /// subscription. Also clears the rejoin intent.
    public func leave(timeout: Duration? = nil) async throws {
        try await client.leave(topic: topic, timeout: timeout)
    }

    /// Sends an application event and awaits its `flight:reply` (§4.3) —
    /// request/response over the socket without blocking the channel.
    /// Throws `.timedOut` if the handler chose not to reply.
    @discardableResult
    public func push(
        _ event: String,
        payload: JSONValue = .object([:]),
        timeout: Duration? = nil
    ) async throws -> JSONValue {
        try await client.push(topic: topic, event: event, payload: payload, timeout: timeout)
    }

    /// Fire-and-forget: sends with `ref: null`, so no reply ever comes
    /// (§4.3) — for events whose handler is known not to reply.
    public func send(_ event: String, payload: JSONValue = .object([:])) async throws {
        try await client.send(topic: topic, event: event, payload: payload)
    }

    /// Everything the server pushes on this topic (§3 step 5), as a stream —
    /// mirroring the server's own subscription model (§7.2). Multiple
    /// streams may be open; each sees every message from its creation on.
    public func messages() async -> AsyncStream<ChannelMessage> {
        await client.messages(topic: topic)
    }
}
