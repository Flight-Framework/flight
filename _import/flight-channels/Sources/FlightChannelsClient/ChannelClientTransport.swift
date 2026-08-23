import struct Foundation.URL

/// The client-side transport seam: everything `ChannelClient` needs from a
/// WebSocket, and nothing it doesn't. Mirrors the server's
/// `UpgradedConnection` shape — closure-backed, so any transport (a NIO
/// client, `URLSessionWebSocketTask`, an in-memory test pair) constructs one
/// without this package knowing its internals.
///
/// The client core is deliberately transport-free ("thin, protocol
/// plumbing"): protocol logic — refs, replies, heartbeats, reconnection —
/// is identical across transports and fully testable without a socket.
/// `FlightChannelsTesting` ships the in-memory transport; the E2E suite
/// shows a real one over hummingbird's `WSClient` in a few lines.
public protocol ChannelClientTransport: Sendable {
    /// Opens one WebSocket to `url`, protocol handshake included. Every
    /// call is a fresh connection — reconnection policy lives in
    /// `ChannelClient`, not here.
    func connect(to url: URL) async throws -> ClientTransportConnection
}

/// One live connection: inbound text frames as a throwing stream (finishes
/// on orderly close, throws on transport failure), plus send/close.
public struct ClientTransportConnection: Sendable {
    /// Inbound text frames. Single-consumer: `ChannelClient`'s read loop.
    public let incoming: AsyncThrowingStream<String, any Error>

    private let sendText: @Sendable (String) async throws -> Void
    private let closeConnection: @Sendable () async -> Void

    public init(
        incoming: AsyncThrowingStream<String, any Error>,
        send: @escaping @Sendable (String) async throws -> Void,
        close: @escaping @Sendable () async -> Void
    ) {
        self.incoming = incoming
        self.sendText = send
        self.closeConnection = close
    }

    /// Sends one text frame; throws once the connection is gone.
    public func send(_ text: String) async throws {
        try await sendText(text)
    }

    /// Initiates the closing handshake. Idempotent.
    public func close() async {
        await closeConnection()
    }
}
