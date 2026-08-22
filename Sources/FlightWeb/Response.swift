import Foundation
import HTTPTypes

/// HTTPTypes' names, surfaced under the design doc's vocabulary (§6.2).
public typealias Status = HTTPResponse.Status
public typealias Headers = HTTPFields

/// A response in one of three shapes (§6.2): a complete fixed body, a
/// streaming body written chunk-by-chunk as produced (SSE, large downloads),
/// or a connection-upgrade directive (WebSocket, §6.1).
///
/// Design delta, recorded in README: the doc sketches
/// `case upgrade(handler: any ConnectionUpgradeHandler)`, but the handler's
/// own contract takes the originating `RequestContext` — which a transport
/// never has (§5.3). The case therefore carries an `UpgradeResponse` whose
/// `run` closure was built by the router with the context already captured;
/// the transport performs the protocol switch and calls `run`, still knowing
/// nothing about routing or contexts.
public enum Response: Sendable {
    case fixed(status: Status, headers: Headers, body: Data)
    case streaming(status: Status, headers: Headers, body: AsyncStream<Data>)
    case upgrade(UpgradeResponse)
}

extension Response {
    // MARK: - Fixed-body conveniences

    public static func status(_ status: Status, headers: Headers = [:]) -> Response {
        .fixed(status: status, headers: headers, body: Data())
    }

    public static var noContent: Response { .status(.noContent) }
    public static var notFound: Response {
        .problem(status: .notFound, message: "Not Found")
    }

    public static func text(_ string: String, status: Status = .ok) -> Response {
        var headers: Headers = [:]
        headers[.contentType] = ContentType.text.rawValue
        return .fixed(status: status, headers: headers, body: Data(string.utf8))
    }

    public static func html(_ string: String, status: Status = .ok) -> Response {
        var headers: Headers = [:]
        headers[.contentType] = ContentType.html.rawValue
        return .fixed(status: status, headers: headers, body: Data(string.utf8))
    }

    public static func data(
        _ data: Data,
        contentType: ContentType = .octetStream,
        status: Status = .ok
    ) -> Response {
        var headers: Headers = [:]
        headers[.contentType] = contentType.rawValue
        return .fixed(status: status, headers: headers, body: data)
    }

    public static func json(_ value: some Encodable, status: Status = .ok) throws -> Response {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let body = try encoder.encode(value)
        var headers: Headers = [:]
        headers[.contentType] = ContentType.json.rawValue
        return .fixed(status: status, headers: headers, body: body)
    }

    /// The uniform error-body shape used by `errorResponse(for:context:)`.
    public static func problem(status: Status, message: String) -> Response {
        struct Problem: Encodable {
            let status: Int
            let error: String
        }
        // Encoding a two-field struct of primitives cannot fail.
        return (try? .json(Problem(status: status.code, error: message), status: status))
            ?? .status(status)
    }

    // MARK: - Streaming (§6.2)

    /// Wraps `produce` into a `.streaming` response. The producer runs in its
    /// own task, started immediately; it is cancelled if the consumer stops
    /// reading (client disconnect), and the stream finishes when `produce`
    /// returns even if the producer forgot to call `finish()`.
    public static func streaming(
        status: Status = .ok,
        contentType: ContentType,
        headers: Headers = [:],
        _ produce: @escaping @Sendable (AsyncStream<Data>.Continuation) async -> Void
    ) -> Response {
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        let producer = Task {
            await produce(continuation)
            continuation.finish()
        }
        continuation.onTermination = { reason in
            // Client gone or stream dropped before completion: stop producing.
            if case .cancelled = reason { producer.cancel() }
        }
        var merged = headers
        merged[.contentType] = contentType.rawValue
        return .streaming(status: status, headers: merged, body: stream)
    }

    // MARK: - Upgrade (§6.1)

    /// Built by the routing layer for `@WebSocketMapping` handlers; also
    /// callable directly from a plain handler that constructed its own
    /// `ConnectionUpgradeHandler`.
    public static func upgrade(
        handler: any ConnectionUpgradeHandler,
        context: RequestContext
    ) -> Response {
        .upgrade(UpgradeResponse(handler: handler) { connection in
            try await handler.handle(upgraded: connection, context: context)
        })
    }

    // MARK: - Accessors

    /// The status line, or `.switchingProtocols` for upgrade responses.
    public var status: Status {
        switch self {
        case .fixed(let status, _, _), .streaming(let status, _, _):
            return status
        case .upgrade:
            return .switchingProtocols
        }
    }

    public var headers: Headers {
        switch self {
        case .fixed(_, let headers, _), .streaming(_, let headers, _):
            return headers
        case .upgrade:
            return [:]
        }
    }

    /// The complete body for `.fixed`; nil for streaming/upgrade responses.
    public var bodyData: Data? {
        if case .fixed(_, _, let body) = self { return body }
        return nil
    }

    /// Returns a copy with `value` set for `name` (fixed and streaming
    /// responses; upgrade responses have no header section of their own —
    /// the transport owns the 101 handshake).
    public func settingHeader(_ name: HTTPField.Name, _ value: String) -> Response {
        switch self {
        case .fixed(let status, var headers, let body):
            headers[name] = value
            return .fixed(status: status, headers: headers, body: body)
        case .streaming(let status, var headers, let body):
            headers[name] = value
            return .streaming(status: status, headers: headers, body: body)
        case .upgrade:
            return self
        }
    }
}

/// The `.upgrade` payload (§6.1). `run` is the router-built closure that
/// invokes the handler with the originating request's context; transports
/// call it after the protocol switch and never see the context themselves.
public struct UpgradeResponse: Sendable {
    /// The handler, exposed for introspection and in-process test drivers.
    public let handler: any ConnectionUpgradeHandler
    /// Takes ownership of the upgraded connection for its lifetime.
    public let run: @Sendable (UpgradedConnection) async throws -> Void

    public init(
        handler: any ConnectionUpgradeHandler,
        run: @escaping @Sendable (UpgradedConnection) async throws -> Void
    ) {
        self.handler = handler
        self.run = run
    }
}

/// The handful of content types Flight Web itself needs, plus room for any
/// other via the raw initializer.
public struct ContentType: Sendable, Equatable, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }

    public static let json = ContentType("application/json; charset=utf-8")
    public static let text = ContentType("text/plain; charset=utf-8")
    public static let html = ContentType("text/html; charset=utf-8")
    public static let eventStream = ContentType("text/event-stream")
    public static let octetStream = ContentType("application/octet-stream")

    public var description: String { rawValue }
}
