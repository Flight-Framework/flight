import FlightWeb
import Foundation
import Synchronization

/// The client end of an in-process WebSocket pair (§5.4's "in-memory
/// transport for testing without touching a socket", applied to upgrades).
/// Frames pass verbatim in both directions — no masking, no auto-pong, no
/// close-handshake emulation. Protocol-level behavior is the real
/// transport's job and is tested against `FlightTransport`; this pair tests
/// *handler* behavior.
public final class InMemoryWebSocket: Sendable {
    /// Frames the server handler sent to this client.
    public let frames: AsyncStream<WebSocketFrame>

    private let toServer: AsyncStream<WebSocketFrame>.Continuation
    private let fromServer: AsyncStream<WebSocketFrame>.Continuation
    private let serverTask = Mutex<Task<Void, Never>?>(nil)

    private init(
        frames: AsyncStream<WebSocketFrame>,
        toServer: AsyncStream<WebSocketFrame>.Continuation,
        fromServer: AsyncStream<WebSocketFrame>.Continuation
    ) {
        self.frames = frames
        self.toServer = toServer
        self.fromServer = fromServer
    }

    /// Builds a connected pair: the `WebSocketConnection` to hand to a
    /// server-side `WebSocketUpgradeHandler`, and the client end.
    public static func makeConnectedPair() -> (server: WebSocketConnection, client: InMemoryWebSocket) {
        let (clientInbound, fromServer) = AsyncStream<WebSocketFrame>.makeStream()
        let (serverInbound, toServer) = AsyncStream<WebSocketFrame>.makeStream()

        let server = WebSocketConnection(
            frames: serverInbound,
            send: { frame in
                fromServer.yield(frame)
                if case .close = frame { fromServer.finish() }
            },
            close: { code, reason in
                fromServer.yield(.close(code: code, reason: reason))
                fromServer.finish()
            }
        )
        let client = InMemoryWebSocket(
            frames: clientInbound,
            toServer: toServer,
            fromServer: fromServer
        )
        return (server, client)
    }

    // MARK: - Client actions

    public func send(_ frame: WebSocketFrame) {
        toServer.yield(frame)
        // A `.close` frame ends the stream here as it does on the wire.
        // Without this, the raw-frame API could hand a handler a close and
        // then leave it awaiting a stream end that never came — a hang the
        // typed `close()` never had.
        if case .close = frame { toServer.finish() }
    }

    public func send(_ text: String) {
        toServer.yield(.text(text))
    }

    public func send(_ binary: Data) {
        toServer.yield(.binary(binary))
    }

    /// Whether ``deinit`` should stop the handler. Off by default: a
    /// hand-built pair may legitimately outlive the object that made it.
    private let cancelsOnDeinit = Mutex(false)

    /// Delivers a close frame to the handler and ends its frame stream —
    /// the in-memory equivalent of the peer going away.
    public func close(code: WebSocketCloseCode = .normalClosure, reason: String = "") {
        toServer.yield(.close(code: code, reason: reason))
        toServer.finish()
    }

    /// Awaits the server handler's completion (after `close()`), so tests
    /// can assert on its side effects without racing it.
    public func waitForServer() async {
        let task = serverTask.withLock { $0 }
        await task?.value
    }

    // MARK: - Wiring (used by TestClient)

    public func attach(serverTask task: Task<Void, Never>) {
        serverTask.withLock { $0 = task }
    }

    public func finishFromServer() {
        fromServer.finish()
    }

    /// Stops the server handler when this client is released.
    ///
    /// A test that dropped its client without calling `close()` left the
    /// handler task parked on the frame stream forever — one leaked task per
    /// such test, and a suite that accumulates them looks like a flake later.
    public func cancelServerTaskOnDeinit() {
        cancelsOnDeinit.withLock { $0 = true }
    }

    deinit {
        guard cancelsOnDeinit.withLock({ $0 }) else { return }
        toServer.finish()
        serverTask.withLock { $0 }?.cancel()
    }
}
