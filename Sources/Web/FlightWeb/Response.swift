import Foundation
import HTTPTypes

/// HTTPTypes' names, surfaced under the design doc's vocabulary (§6.2).
// `Status` and `Headers` used to be module-level typealiases here. They are
// gone deliberately: `Status` in particular is a word applications use — an
// order status, a job status — and a module-level alias for it turned
// `import FlightWeb` into a source of shadowing surprises in code that had
// nothing to do with HTTP. HTTPTypes' own names are re-exported instead, and
// `.ok` / `[:]` still infer at every call site.

/// A response in one of four shapes (§6.2): a complete fixed body, a
/// streaming body written chunk-by-chunk as produced (SSE), a byte-range of
/// a sized source (files, blobs — the shape downloads want), or a
/// connection-upgrade directive (WebSocket, §6.1).
///
/// `.file` earns its place beside `.streaming` for one reason: **it knows
/// its length.** A streaming body goes out chunked with no `Content-Length`,
/// which is right for SSE and wrong for a download — no progress bars, no
/// resumption, no cheap cache validation. `.file` carries a sized
/// ``ByteSource`` plus the half-open range to send, so the transport writes
/// an exact length and streams the bytes in constant memory. It is also the
/// case neither incumbent Swift framework can retrofit — their body types
/// shipped `ByteBuffer`-only, foreclosing kernel-side file transfer forever;
/// carrying the source (not its bytes) keeps that door open for a future
/// transport even though today's writes chunks.
///
/// Design delta, recorded in README: the doc sketches
/// `case upgrade(handler: any ConnectionUpgradeHandler)`, but the handler's
/// own contract takes the originating `RequestContext` — which a transport
/// never has (§5.3). The case therefore carries an `UpgradeResponse` whose
/// `run` closure was built by the router with the context already captured;
/// the transport performs the protocol switch and calls `run`, still knowing
/// nothing about routing or contexts.
public enum Response: Sendable {
    case fixed(status: HTTPResponse.Status, headers: HTTPFields, body: Data)
    case streaming(status: HTTPResponse.Status, headers: HTTPFields, body: AsyncStream<Data>)
    case file(FileResponse)
    case upgrade(UpgradeResponse)
}

/// The `.file` payload: which bytes of which source, under which headers.
///
/// Built by ``serveContent(for:_:)`` in the normal case — that is where
/// conditional requests, ranges, and validator headers are decided — and
/// constructible directly by anything that already knows exactly what it
/// wants to send.
public struct FileResponse: Sendable {
    public let status: HTTPResponse.Status
    /// Complete, including `Content-Length` for `range.count` — the
    /// transport writes these verbatim.
    public let headers: HTTPFields
    public let source: any ByteSource
    /// Half-open, within `0..<source.count`. Empty is legal (a zero-length
    /// file): headers only, no read ever issued.
    public let range: Range<Int64>
    public let chunkSize: Int

    public init(
        status: HTTPResponse.Status,
        headers: HTTPFields,
        source: any ByteSource,
        range: Range<Int64>,
        chunkSize: Int = FileByteSource.defaultChunkSize
    ) {
        precondition(
            range.lowerBound >= 0 && range.upperBound <= source.count,
            "range \(range) outside 0..<\(source.count)")
        self.status = status
        self.headers = headers
        self.source = source
        self.range = range
        self.chunkSize = chunkSize
    }
}

extension Response {
    // MARK: - Fixed-body conveniences

    public static func status(_ status: HTTPResponse.Status, headers: HTTPFields = [:]) -> Response {
        .fixed(status: status, headers: headers, body: Data())
    }

    public static var noContent: Response { .status(.noContent) }
    public static var notFound: Response {
        .problem(status: .notFound, message: "Not Found")
    }

    public static func text(_ string: String, status: HTTPResponse.Status = .ok) -> Response {
        var headers: HTTPFields = [:]
        headers[.contentType] = ContentType.text.rawValue
        return .fixed(status: status, headers: headers, body: Data(string.utf8))
    }

    public static func html(_ string: String, status: HTTPResponse.Status = .ok) -> Response {
        var headers: HTTPFields = [:]
        headers[.contentType] = ContentType.html.rawValue
        return .fixed(status: status, headers: headers, body: Data(string.utf8))
    }

    public static func data(
        _ data: Data,
        contentType: ContentType = .octetStream,
        status: HTTPResponse.Status = .ok
    ) -> Response {
        var headers: HTTPFields = [:]
        headers[.contentType] = contentType.rawValue
        return .fixed(status: status, headers: headers, body: data)
    }

    /// JSON body, `application/json`.
    ///
    /// `encoder` defaults to ``WebCoders/default``'s. A handler that wants the
    /// application's configured encoder should return the value itself and let
    /// `ResponseEncodable` do it, or pass `context.coders.jsonEncoder` here —
    /// this is a static, so it cannot reach the container on its own.
    public static func json(
        _ value: some Encodable,
        status: HTTPResponse.Status = .ok,
        encoder: JSONEncoder = WebCoders.default.jsonEncoder
    ) throws -> Response {
        let body = try encoder.encode(value)
        var headers: HTTPFields = [:]
        headers[.contentType] = ContentType.json.rawValue
        return .fixed(status: status, headers: headers, body: body)
    }

    /// The uniform error-body shape used by `errorResponse(for:context:)`.
    /// An error body, rendered by `render` — RFC 9457 `problem+json` unless
    /// the application configured otherwise.
    ///
    /// Call sites that have a `RequestContext` should pass
    /// `context.coders.renderError`, so the application's choice is honored.
    public static func problem(
        status: HTTPResponse.Status,
        message: String,
        render: (HTTPResponse.Status, String) -> Response = ProblemDetails.render
    ) -> Response {
        render(status, message)
    }

    // MARK: - Streaming (§6.2)

    /// Wraps `produce` into a `.streaming` response.
    ///
    /// The producer runs in its own task, started on the transport's first
    /// read rather than at construction, and every ``ResponseBodyWriter/write(_:)``
    /// suspends until the chunk has been taken — so a producer faster than
    /// its client is slowed by it rather than buffered ahead of it. It is
    /// cancelled if the consumer stops reading (client disconnect), and the
    /// stream finishes when `produce` returns even if the producer forgot to
    /// call `finish()`.
    ///
    /// The stream handed to the transport is still a plain
    /// `AsyncStream<Data>`; it is built by unfolding, so demand — not the
    /// producer's enthusiasm — decides when the next chunk is made.
    public static func streaming(
        status: HTTPResponse.Status = .ok,
        contentType: ContentType,
        headers: HTTPFields = [:],
        _ produce: @escaping @Sendable (ResponseBodyWriter) async -> Void
    ) -> Response {
        let handoff = ResponseBodyHandoff()
        let producer = ResponseBodyProducer(handoff: handoff) { handoff in
            Task {
                await produce(ResponseBodyWriter(handoff: handoff))
                handoff.finish()
            }
        }
        let stream = AsyncStream<Data> {
            producer.ensureStarted()
            return await handoff.next()
        } onCancel: {
            producer.stop()
        }
        var merged = headers
        merged[.contentType] = contentType.rawValue
        return .streaming(status: status, headers: merged, body: stream)
    }

    // MARK: - Upgrade (§6.1)

    /// Built by the routing layer for `@WebSocketMapping` handlers; also
    /// callable directly from a plain handler that constructed its own
    /// `WebSocketUpgradeHandler`.
    public static func upgrade(
        handler: any WebSocketUpgradeHandler,
        context: RequestContext
    ) -> Response {
        .upgrade(
            .webSocket(
                WebSocketUpgrade(handler: handler) { connection in
                    try await handler.handle(upgraded: connection, context: context)
                }))
    }

    // MARK: - Accessors

    /// The status line, or `.switchingProtocols` for upgrade responses.
    public var status: HTTPResponse.Status {
        switch self {
        case .fixed(let status, _, _), .streaming(let status, _, _):
            return status
        case .file(let file):
            return file.status
        case .upgrade:
            return .switchingProtocols
        }
    }

    public var headers: HTTPFields {
        switch self {
        case .fixed(_, let headers, _), .streaming(_, let headers, _):
            return headers
        case .file(let file):
            return file.headers
        case .upgrade:
            return [:]
        }
    }

    /// The complete body for `.fixed`; nil for streaming/file/upgrade
    /// responses, whose bytes exist only as they are written.
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
        case .file(let file):
            var headers = file.headers
            headers[name] = value
            return .file(
                FileResponse(
                    status: file.status, headers: headers, source: file.source,
                    range: file.range, chunkSize: file.chunkSize))
        case .upgrade:
            return self
        }
    }
}

/// The `.upgrade` payload (§6.1), discriminated by protocol kind.
///
/// An enum, deliberately, and the cases will grow: RFC 8441 makes "upgrade"
/// a family (`websocket` today; WebTransport and `connect-udp` are the known
/// next members), and the kinds do not share a connection shape a transport
/// could serve generically — each needs its own wire handling. A new kind is
/// a new case, and every transport *fails to compile* until it decides what
/// to do with it. That is the point: a transport silently 500ing a protocol
/// it never heard of would hide exactly the capability gap that should be a
/// build error.
public enum UpgradeResponse: Sendable {
    case webSocket(WebSocketUpgrade)
}

/// The WebSocket kind's payload. `run` is the router-built closure that
/// invokes the handler with the originating request's context; transports
/// call it after the protocol switch and never see the context themselves.
public struct WebSocketUpgrade: Sendable {
    /// The handler, exposed for introspection and in-process test drivers.
    public let handler: any WebSocketUpgradeHandler
    /// Takes ownership of the upgraded connection for its lifetime.
    public let run: @Sendable (WebSocketConnection) async throws -> Void

    public init(
        handler: any WebSocketUpgradeHandler,
        run: @escaping @Sendable (WebSocketConnection) async throws -> Void
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
