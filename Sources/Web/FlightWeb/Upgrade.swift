import Foundation

/// The generic connection-upgrade hook (§6.1): a module that wants to own a
/// long-lived, stateful connection implements this, without Flight Web
/// needing to know *why*. WebSocket is the first concrete consumer, shipped
/// as part of Flight Web itself; a future reactive templating engine is a
/// later consumer of the same contract, not the reason it exists.
///
/// Dependency direction, stated explicitly (§6.1): consumer → Flight Web →
/// Flight Core, never the reverse — Web only ever sees this protocol, never
/// a specific consumer's own types.
public protocol ConnectionUpgradeHandler: Sendable {
    /// Takes ownership of the now-upgraded connection for its lifetime.
    /// Flight Web's involvement ends the moment this is called — no further
    /// middleware runs, no response encoding happens on Web's side.
    func handle(upgraded connection: UpgradedConnection, context: RequestContext) async throws
}

/// One WebSocket frame, post protocol-handling: the transport owns
/// fragmentation reassembly, masking, and the close handshake; the developer
/// owns message semantics (§6.1).
public enum WebSocketFrame: Sendable, Equatable {
    case text(String)
    case binary(Data)
    /// Delivered for observability; the transport already answered with a
    /// pong (RFC 6455 §5.5.2) before delivering it.
    case ping(Data)
    case pong(Data)
    /// The peer initiated (or acknowledged) closing. Delivered last; the
    /// frame stream finishes immediately after.
    case close(code: WebSocketCloseCode, reason: String)
}

public struct WebSocketCloseCode: Sendable, Equatable, RawRepresentable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }
    public init(_ rawValue: UInt16) { self.rawValue = rawValue }

    public static let normalClosure = WebSocketCloseCode(1000)
    public static let goingAway = WebSocketCloseCode(1001)
    public static let protocolError = WebSocketCloseCode(1002)
    public static let unacceptableData = WebSocketCloseCode(1003)
    /// RFC 6455: a close frame may omit the code entirely.
    public static let noStatus = WebSocketCloseCode(1005)
}

/// A thin `Sendable` wrapper over async send/receive of WebSocket frames
/// (§6.1). Closure-backed so any transport — the NIO default, an in-memory
/// test pair — can construct one without Flight Web knowing its internals.
///
/// `frames` is a single-consumer stream: iterate it from exactly one task
/// (normally the `ConnectionUpgradeHandler` body). It finishes when the peer
/// closes or the transport shuts the connection down.
public struct UpgradedConnection: Sendable {
    /// Inbound frames, protocol frames already handled by the transport.
    public let frames: AsyncStream<WebSocketFrame>

    private let sendFrame: @Sendable (WebSocketFrame) async throws -> Void
    private let closeConnection: @Sendable (WebSocketCloseCode, String) async throws -> Void

    public init(
        frames: AsyncStream<WebSocketFrame>,
        send: @escaping @Sendable (WebSocketFrame) async throws -> Void,
        close: @escaping @Sendable (WebSocketCloseCode, String) async throws -> Void
    ) {
        self.frames = frames
        self.sendFrame = send
        self.closeConnection = close
    }

    /// Sends one frame. Throws `WebSocketError.connectionClosed` once the
    /// connection is gone.
    public func send(_ frame: WebSocketFrame) async throws {
        try await sendFrame(frame)
    }

    public func send(_ text: String) async throws {
        try await sendFrame(.text(text))
    }

    public func send(_ binary: Data) async throws {
        try await sendFrame(.binary(binary))
    }

    /// Initiates the closing handshake. Idempotent: closing an already
    /// closed connection is a no-op, not an error.
    public func close(
        code: WebSocketCloseCode = .normalClosure,
        reason: String = ""
    ) async throws {
        try await closeConnection(code, reason)
    }
}

public enum WebSocketError: Error, Sendable, Equatable, CustomStringConvertible {
    case connectionClosed
    case invalidUTF8InTextFrame

    public var description: String {
        switch self {
        case .connectionClosed:
            return "The WebSocket connection is closed."
        case .invalidUTF8InTextFrame:
            return "Peer sent a text frame that is not valid UTF-8 (RFC 6455 §8.1)."
        }
    }
}
