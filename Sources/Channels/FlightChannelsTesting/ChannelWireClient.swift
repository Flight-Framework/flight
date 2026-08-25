import FlightChannels
import FlightWeb
import FlightWebTesting

/// A deliberately dumb protocol driver for server-side tests: sends and
/// receives raw envelopes over an in-process upgrade (`InMemoryWebSocket`),
/// no client-library behavior (no heartbeats, no reconnect, no correlation)
/// — so tests assert on exactly what the server puts on the wire.
///
/// Not `Sendable`: it wraps the single-consumer frame iterator, so it
/// belongs to one test task — the way tests use it anyway.
public final class ChannelWireClient {
    public let socket: InMemoryWebSocket
    private var inbound: AsyncStream<WebSocketFrame>.Iterator

    public init(socket: InMemoryWebSocket) {
        self.socket = socket
        self.inbound = socket.frames.makeAsyncIterator()
    }

    public func send(_ envelope: Envelope) throws {
        socket.send(try envelope.encodedText())
    }

    public func send(ref: String?, topic: String, event: String, payload: JSONValue = .object([:])) throws {
        try send(Envelope(ref: ref, topic: topic, event: event, payload: payload))
    }

    /// The next frame of any kind, or nil when the server closed.
    public func nextFrame() async -> WebSocketFrame? {
        await inbound.next()
    }

    /// The next *text* frame decoded as an envelope; nil when the stream
    /// ends first (a `.close` frame reports the end too). Skips ping/pong;
    /// fails the decode loudly.
    public func nextEnvelope() async throws -> Envelope? {
        while let frame = await nextFrame() {
            switch frame {
            case .text(let text):
                return try Envelope(text: text)
            case .close:
                return nil
            case .binary, .ping, .pong:
                continue
            }
        }
        return nil
    }

    public func close() {
        socket.close()
    }
}
