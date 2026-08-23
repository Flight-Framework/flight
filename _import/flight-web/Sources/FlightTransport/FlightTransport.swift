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
                switch await dispatch(request) {
                case .upgrade(let upgradeResponse):
                    return .upgrade([:]) { inbound, outbound, _ in
                        try await Self.runUpgradedConnection(
                            upgradeResponse,
                            inbound: inbound,
                            outbound: outbound,
                            maxMessageBytes: configuration.maxWebSocketFrameBytes
                        )
                    }
                case let refused:
                    // HummingbirdCore answers every refused upgrade with its
                    // own 400 + connection close; the routed status is the
                    // in-process truth (TestClient surfaces it) but is not
                    // writable through this seam — README delta 8.
                    logger.debug("websocket upgrade refused", metadata: [
                        "path": "\(head.path ?? "/")",
                        "status": "\(refused.status.code)",
                    ])
                    return .dontUpgrade
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
        do {
            var collected = try await request.body.collect(upTo: configuration.maxRequestBodyBytes)
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
    static func runUpgradedConnection(
        _ upgradeResponse: UpgradeResponse,
        inbound: WebSocketInboundStream,
        outbound: WebSocketOutboundWriter,
        maxMessageBytes: Int
    ) async throws {
        let (frames, continuation) = AsyncStream<FlightWeb.WebSocketFrame>.makeStream()

        let connection = UpgradedConnection(
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
                while let message = try? await iterator.nextMessage(maxSize: maxMessageBytes) {
                    switch message {
                    case .text(let text):
                        continuation.yield(.text(text))
                    case .binary(let buffer):
                        continuation.yield(.binary(Data(buffer: buffer)))
                    }
                }
                continuation.yield(.close(code: .noStatus, reason: ""))
                continuation.finish()
            }

            // Handler: owns the connection for its lifetime (§6.1). When it
            // returns, HummingbirdCore performs the close handshake.
            group.addTask {
                try? await upgradeResponse.run(connection)
            }

            // Either side finishing ends the session: a returned handler has
            // said everything it will; a finished pump means the peer closed
            // and the handler's frame iteration has ended.
            await group.next()
            group.cancelAll()
        }
    }

}
