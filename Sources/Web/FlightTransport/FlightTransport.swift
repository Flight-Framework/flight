import FlightWeb
import Foundation
import HTTPTypes
import HummingbirdCore
import HummingbirdTLS
import HummingbirdWebSocket
import Logging
import NIOCore
import NIOPosix
import NIOWebSocket
import ServiceLifecycle
import WSCore

/// The default `ServerTransport` (§5.2): wraps HummingbirdCore — a mature,
/// versioned low-level HTTP transport — rather than hand-rolling byte-level
/// HTTP. HTTP/1.1 parsing correctness, keep-alive, pipelining, and the
/// WebSocket protocol machinery are commodity infrastructure (§10);
/// Flight's differentiation is compile-time DI and the unified registration
/// pipeline, all of which run *inside* the `dispatch` closure this struct
/// is handed.
///
/// This is the ONLY place in all of Flight where the wrapped library's
/// types appear (§5.6). Routing, middleware, `RequestContext`, and the
/// macros are built on HTTPTypes with zero knowledge that HummingbirdCore
/// exists — swapping it for raw NIO, an in-memory test transport, or
/// anything else changes this one target and nothing above it.
///
/// The `dispatch` boundary is structured `async` (§5.5); streaming
/// responses are written chunk-by-chunk as produced, never buffered (§6.2);
/// `.upgrade` responses drive the 101 handshake and hand the frame stream
/// to the handler (§6.1).
public struct FlightTransport: ServerTransport {
    public typealias Configuration = FlightTransportConfiguration

    let configuration: FlightTransportConfiguration
    let dispatch: Dispatch
    let logger = Logger(label: "flight.web.transport")

    public init(configuration: FlightTransportConfiguration, dispatch: Dispatch) {
        self.configuration = configuration
        self.dispatch = dispatch
    }

    // MARK: - Service (§5.3: suspends until shutdown)

    public func run() async throws {
        let dispatch = self.dispatch
        let configuration = self.configuration
        let logger = self.logger

        let plain = HTTPServerBuilder.http1WebSocketUpgrade(
            configuration: .init(
                http1: .init(),
                ws: WebSocketServerConfiguration(
                    maxFrameSize: configuration.maxWebSocketFrameBytes,
                    validateUTF8: true
                )
            ),
            shouldUpgrade: { (head: HTTPRequest, _: any Channel, _: Logger) async throws
                -> ShouldUpgradeResult<WebSocketDataHandler<HTTP1WebSocketUpgradeChannel.Context>> in
                // Upgrade requests carry no body by construction (RFC 6455 §4.1).
                let request = Request(head: head, body: Data())

                // Ask the route table first. Dispatching every upgrade-shaped
                // request would run ordinary HTTP handlers — their writes,
                // their side effects — and then discard the response, since no
                // upgrade can be performed at a route that never offered one.
                // That made any GET route reachable by an unauthenticated
                // client willing to attach upgrade headers.
                guard dispatch.acceptsUpgrade(request) else {
                    logger.debug("websocket upgrade refused: not an upgrade route", metadata: [
                        "path": "\(head.path ?? "/")"
                    ])
                    return .dontUpgrade
                }

                // The upgrade decision needs the *routed* answer, middleware
                // included, so the pipeline runs for genuine upgrade routes.
                let routed = await dispatch(request)
                guard case .upgrade(let upgrade) = routed else {
                    // HummingbirdCore answers every refused upgrade with its
                    // own 400 + connection close; the routed status is the
                    // in-process truth (TestClient surfaces it) but is not
                    // writable through this seam — see design delta 8.
                    logger.debug("websocket upgrade refused", metadata: [
                        "path": "\(head.path ?? "/")",
                        "status": "\(routed.status.code)",
                    ])
                    return .dontUpgrade
                }
                // Switched over `UpgradeResponse` itself, with no catch-all.
                // `UpgradeResponse`'s own doc promises "every transport fails
                // to compile" when a kind is added — and the one transport
                // that exists defeated it: a `case let refused` after
                // `.upgrade(.webSocket)` swallowed a future
                // `.upgrade(.webTransport)` and logged it as refused with
                // status 101. Now a new kind really does break this build,
                // which is the seam working.
                switch upgrade {
                case .webSocket(let webSocketUpgrade):
                    return .upgrade([:]) { inbound, outbound, _ in
                        try await Self.runUpgradedConnection(
                            webSocketUpgrade,
                            inbound: inbound,
                            outbound: outbound,
                            maxMessageBytes: configuration.maxWebSocketFrameBytes,
                            logger: logger
                        )
                    }
                }
            }
        )

        // TLS wraps whatever channel the builder produced, so the upgrade
        // path above is unchanged by it — `wss://` is `ws://` inside TLS.
        let builder =
            try configuration.tls.map {
                try HTTPServerBuilder.tls(plain, tlsConfiguration: $0.nioConfiguration())
            } ?? plain

        let server = try builder
            .buildServer(
            configuration: ServerConfiguration(
                address: .hostname(configuration.host, port: configuration.port),
                serverName: "FlightWeb",
                backlog: configuration.backlog,
                reuseAddress: true
            ),
            eventLoopGroup: MultiThreadedEventLoopGroup.singleton,
            logger: logger,
            responder: { request, responseWriter, _ in
                try await respond(to: request, writer: responseWriter)
            },
            onServerRunning: { channel in
                let port = channel.localAddress?.port ?? configuration.port
                logger.info("flight transport listening", metadata: [
                    "host": "\(configuration.host)",
                    "port": "\(port)",
                ])
                configuration.onBound?(port)
            }
        )

        try await server.run()
        logger.info("flight transport stopped")
    }

    // MARK: - HTTP responder

    /// The §5.6 containment point: HummingbirdCore's request in, Flight's
    /// `dispatch` in the middle, HummingbirdCore's response writer out.
    private func respond(
        to request: HummingbirdCore.Request,
        writer: consuming ResponseWriter
    ) async throws {
        let isHeadRequest = request.head.method == .head

        // Expect: 100-continue — answer the interim response before the
        // client will send the body.
        if request.headers[.expect]?.lowercased() == "100-continue" {
            try await writer.writeInformationalHead(HTTPResponse(status: .continue))
        }

        let response: FlightWeb.Response
        // The route table decides how this body is delivered — asked before
        // any of it is read, the same shape as the upgrade check.
        switch dispatch.bodyMode(Request(head: request.head)) {
        case .streaming(let routeCap):
            response = await Self.dispatchStreaming(
                request: request,
                dispatch: dispatch,
                byteCap: routeCap ?? configuration.maxRequestBodyBytes)
        case .buffered(let routeCap):
            do {
                var collected = try await request.body.collect(
                    upTo: routeCap ?? configuration.maxRequestBodyBytes)
                let body = collected.readData(length: collected.readableBytes) ?? Data()
                response = await dispatch(Request(head: request.head, body: body))
            } catch is NIOTooManyBytesError {
                // Bounded before dispatch ever runs. HummingbirdCore drains
                // the remainder; `connection: close` hints the client to stop.
                let problem = FlightWeb.Response.problem(
                    status: .contentTooLarge, message: "Content Too Large"
                )
                var head = HTTPResponse(status: problem.status)
                head.headerFields = problem.headers
                head.headerFields[.connection] = "close"
                head.headerFields[.contentLength] = "\(problem.bodyData?.count ?? 0)"
                try await writer.write(
                    response: head,
                    body: .init(byteBuffer: ByteBuffer(bytes: problem.bodyData ?? Data()))
                )
                return
            }
        }

        switch response {
        case .fixed(let status, let headers, let bodyData):
            var head = HTTPResponse(status: status)
            head.headerFields = headers
            if Self.statusAllowsBody(status) {
                head.headerFields[.contentLength] = "\(bodyData.count)"
            }
            if isHeadRequest || bodyData.isEmpty || !Self.statusAllowsBody(status) {
                // Head (and end) only — correct for HEAD, 204, and empty bodies.
                try await writer.writeResponse(head)
            } else {
                try await writer.write(
                    response: head,
                    body: .init(byteBuffer: ByteBuffer(bytes: bodyData))
                )
            }

        case .file(let file):
            var head = HTTPResponse(status: file.status)
            head.headerFields = file.headers
            // serveContent always sets Content-Length; this is the safety
            // net for a hand-built FileResponse, because a sized body with
            // no declared length silently downgrades to chunked coding —
            // losing exactly the property .file exists to provide.
            if Self.statusAllowsBody(file.status), head.headerFields[.contentLength] == nil {
                head.headerFields[.contentLength] = "\(file.range.count)"
            }
            if isHeadRequest || file.range.isEmpty || !Self.statusAllowsBody(file.status) {
                // HEAD carries the full header set — Content-Length and
                // Content-Range included — with no read ever issued against
                // the source: the descriptor just closes unread.
                try await writer.writeResponse(head)
            } else {
                var bodyWriter = try await writer.writeHead(head)
                // A mid-stream throw (source truncated under us, disk error)
                // propagates out and tears the connection down with the body
                // short of its declared length — the client sees a broken
                // transfer, never a silently complete-looking wrong one.
                for try await chunk in file.source.chunks(
                    in: file.range, chunkSize: file.chunkSize)
                {
                    guard !chunk.isEmpty else { continue }
                    try await bodyWriter.write(ByteBuffer(bytes: chunk))
                }
                try await bodyWriter.finish(nil)
            }

        case .streaming(let status, let headers, let bodyStream):
            var head = HTTPResponse(status: status)
            head.headerFields = headers
            if isHeadRequest {
                try await writer.writeResponse(head)
                return
            }
            // No content-length → HummingbirdCore emits chunked transfer
            // coding and writes each chunk as produced, never buffering
            // (§6.2). A failed write (client gone) throws out of this loop,
            // dropping the stream — which cancels the producer.
            var bodyWriter = try await writer.writeHead(head)
            for await chunk in bodyStream {
                guard !chunk.isEmpty else { continue }
                try await bodyWriter.write(ByteBuffer(bytes: chunk))
            }
            try await bodyWriter.finish(nil)

        case .upgrade:
            // An upgrade route matched a request that never asked to
            // upgrade (no WebSocket handshake headers).
            let problem = FlightWeb.Response.problem(
                status: .upgradeRequired, message: "Upgrade Required"
            )
            var head = HTTPResponse(status: .upgradeRequired)
            head.headerFields = problem.headers
            head.headerFields[.upgrade] = "websocket"
            head.headerFields[.contentLength] = "\(problem.bodyData?.count ?? 0)"
            try await writer.write(
                response: head,
                body: .init(byteBuffer: ByteBuffer(bytes: problem.bodyData ?? Data()))
            )
        }
    }

    /// 1xx/204/304 responses carry neither body nor content-length.
    private static func statusAllowsBody(_ status: HTTPResponse.Status) -> Bool {
        switch status.code {
        case 100..<200, 204, 304: return false
        default: return true
        }
    }

    // MARK: - WebSocket bridge (§6.1)

    /// Bridges WSCore's (inbound, outbound) pair to FlightWeb's
    /// `UpgradedConnection` and runs the routed handler. Frame-level
    /// protocol work — masking, fragmentation reassembly, ping auto-reply,
    /// UTF-8 validation, the close handshake — is HummingbirdCore's (§6.1:
    /// "leaving frame-level protocol handling to the transport").
    /// Streams the request body through to the handler as it arrives.
    ///
    /// **Pull-based on purpose.** The obvious shape — a task feeding an
    /// `AsyncThrowingStream` — is wrong here, because that stream's buffer
    /// is *unbounded*: the feeder would race ahead reading a multi-gigabyte
    /// upload entirely into memory while the API claimed to stream it,
    /// which is precisely the property streaming exists to provide. Pulling
    /// one chunk per consumer demand instead makes backpressure flow from
    /// the handler through to the socket, so a slow handler slows the
    /// client rather than filling the server's RAM.
    static func dispatchStreaming(
        request: HummingbirdCore.Request,
        dispatch: Dispatch,
        byteCap: Int
    ) async -> FlightWeb.Response {
        let contentLength = request.headers[.contentLength].flatMap { Int64($0) }
        let puller = BodyPuller(request.body, byteCap: byteCap)
        var streamed = FlightWeb.Request(head: request.head)
        streamed.bodyStream = RequestBodyStream(
            expectedBytes: contentLength,
            chunks: AsyncThrowingStream { try await puller.next() })
        return await dispatch(streamed)
    }

    static func runUpgradedConnection(
        _ upgrade: WebSocketUpgrade,
        inbound: WebSocketInboundStream,
        outbound: WebSocketOutboundWriter,
        maxMessageBytes: Int,
        logger: Logger
    ) async throws {
        let (frames, continuation) = AsyncStream<FlightWeb.WebSocketFrame>.makeStream()

        let connection = WebSocketConnection(
            frames: frames,
            send: { frame in
                do {
                    switch frame {
                    case .text(let text):
                        try await outbound.write(.text(text))
                    case .binary(let data):
                        try await outbound.write(.binary(ByteBuffer(bytes: data)))
                    case .ping(let data):
                        try await outbound.write(
                            .custom(.init(fin: true, opcode: .ping, data: ByteBuffer(bytes: data)))
                        )
                    case .pong(let data):
                        try await outbound.write(
                            .custom(.init(fin: true, opcode: .pong, data: ByteBuffer(bytes: data)))
                        )
                    case .close(let code, let reason):
                        try await outbound.close(.init(codeNumber: Int(code.rawValue)), reason: reason)
                    }
                } catch is CancellationError {
                    throw WebSocketError.connectionClosed
                } catch let error as NIOCore.ChannelError where error == .ioOnClosedChannel {
                    throw WebSocketError.connectionClosed
                }
            },
            close: { code, reason in
                try? await outbound.close(.init(codeNumber: Int(code.rawValue)), reason: reason)
            }
        )

        await withTaskGroup(of: Void.self) { group in
            // Pump: complete messages (reassembled, validated) → FlightWeb
            // frames. The stream finishing is the definitive close signal; a
            // synthesized `.close` frame precedes it so handlers written
            // against the in-memory transport behave identically here.
            group.addTask {
                var iterator = inbound.makeAsyncIterator()
                // `try?` used to swallow *why* the stream ended, so a peer
                // closing, an oversized message and a protocol error were all
                // indistinguishable to the handler: each synthesized
                // `.close(code: .noStatus, reason: "")`. The in-memory
                // transport delivers the test's real close code verbatim, so
                // a handler branching on the code passed its tests and did
                // something else in production — the opposite of "handlers
                // behave identically on the in-memory transport and the wire".
                //
                // The peer's own close code is still not recoverable here:
                // WSCore consumes the close frame in its state machine and
                // this stream simply ends, so a clean end honestly reports
                // "no status". What changed is that an *abnormal* end no
                // longer pretends to be a clean one.
                do {
                    while let message = try await iterator.nextMessage(maxSize: maxMessageBytes) {
                        switch message {
                        case .text(let text):
                            continuation.yield(.text(text))
                        case .binary(let buffer):
                            continuation.yield(.binary(Data(buffer: buffer)))
                        }
                    }
                    continuation.yield(.close(code: .noStatus, reason: ""))
                } catch is CancellationError {
                    continuation.yield(.close(code: .goingAway, reason: "server shutting down"))
                } catch {
                    // WSCore's own error type is `package`, so the reason
                    // travels as text rather than as a matched case — still
                    // "message too large" or "protocol error" where it used
                    // to be silence.
                    logger.debug(
                        "websocket inbound stream ended abnormally",
                        metadata: ["error": "\(error)"])
                    continuation.yield(.close(code: .protocolError, reason: "\(error)"))
                }
                continuation.finish()
            }

            // Handler: owns the connection for its lifetime (§6.1). When it
            // returns, HummingbirdCore performs the close handshake.
            group.addTask {
                do {
                    try await upgrade.run(connection)
                } catch is CancellationError {
                    // The other half of the group ended first; ordinary.
                } catch {
                    // Discarded with no log at all, so a handler that crashed
                    // was invisible even at debug level — the connection just
                    // closed and nothing anywhere said why.
                    logger.debug(
                        "websocket handler threw", metadata: ["error": "\(error)"])
                }
            }

            // Either side finishing ends the session: a returned handler has
            // said everything it will; a finished pump means the peer closed
            // and the handler's frame iteration has ended.
            await group.next()
            group.cancelAll()
        }
    }

}


/// One chunk of the request body per consumer demand, with the route's
/// cumulative cap enforced as bytes pass. Holds the transport's body
/// iterator outside any actor because `next()` is mutating and async;
/// access is serialized by ``RequestBodyStream``'s single-consumer
/// contract, which is what the `@unchecked` attests.
final class BodyPuller: @unchecked Sendable {
    private var iterator: HummingbirdCore.RequestBody.AsyncIterator
    private let byteCap: Int
    private var delivered = 0

    init(_ body: HummingbirdCore.RequestBody, byteCap: Int) {
        self.iterator = body.makeAsyncIterator()
        self.byteCap = byteCap
    }

    func next() async throws -> Data? {
        guard var buffer = try await iterator.next() else { return nil }
        let data = buffer.readData(length: buffer.readableBytes) ?? Data()
        delivered += data.count
        guard delivered <= byteCap else {
            throw BodyStreamLimitError(limit: byteCap)
        }
        return data
    }
}
