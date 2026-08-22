import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket
import Testing

/// Real-socket WebSocket sessions against a bound `FlightTransport` (§6.1),
/// driven by NIO's own typed client upgrader.
@Suite("FlightTransport WebSocket wire behavior", .serialized)
struct WebSocketWireTests {

    enum ClientUpgradeResult {
        case websocket(NIOAsyncChannel<WebSocketFrame, WebSocketFrame>)
        case notUpgraded
    }

    /// Performs the client-side handshake and hands the frame channel to `body`.
    private func withWebSocket(
        port: Int,
        path: String,
        _ body: @escaping @Sendable (
            NIOAsyncChannelInboundStream<WebSocketFrame>,
            NIOAsyncChannelOutboundWriter<WebSocketFrame>
        ) async throws -> Void
    ) async throws {
        let upgradeResult: EventLoopFuture<ClientUpgradeResult> = try await ClientBootstrap(
            group: MultiThreadedEventLoopGroup.singleton
        )
        .connect(host: "127.0.0.1", port: port) { channel in
            channel.eventLoop.makeCompletedFuture {
                let upgrader = NIOTypedWebSocketClientUpgrader<ClientUpgradeResult>(
                    upgradePipelineHandler: { channel, _ in
                        channel.eventLoop.makeCompletedFuture {
                            .websocket(
                                try NIOAsyncChannel<WebSocketFrame, WebSocketFrame>(
                                    wrappingChannelSynchronously: channel
                                )
                            )
                        }
                    }
                )
                let requestHead = HTTPRequestHead(
                    version: .http1_1,
                    method: .GET,
                    uri: path,
                    headers: HTTPHeaders([("Host", "localhost"), ("Content-Length", "0")])
                )
                let configuration = NIOTypedHTTPClientUpgradeConfiguration(
                    upgradeRequestHead: requestHead,
                    upgraders: [upgrader],
                    notUpgradingCompletionHandler: { channel in
                        channel.eventLoop.makeCompletedFuture { .notUpgraded }
                    }
                )
                return try channel.pipeline.syncOperations.configureUpgradableHTTPClientPipeline(
                    configuration: .init(upgradeConfiguration: configuration)
                )
            }
        }

        switch try await upgradeResult.get() {
        case .notUpgraded:
            Issue.record("server refused the upgrade for \(path)")
        case .websocket(let channel):
            try await channel.executeThenClose { inbound, outbound in
                try await body(inbound, outbound)
            }
        }
    }

    private func maskedText(_ text: String) -> WebSocketFrame {
        WebSocketFrame(
            fin: true,
            opcode: .text,
            maskKey: WebSocketMaskingKey([0x0a, 0x0b, 0x0c, 0x0d]),
            data: ByteBuffer(string: text)
        )
    }

    private func text(of frame: WebSocketFrame) -> String? {
        guard frame.opcode == .text else { return nil }
        var data = frame.unmaskedData
        return data.readString(length: data.readableBytes)
    }

    @Test func upgradeHandshakeAndEcho() async throws {
        try await withRunningServer { port in
            try await withWebSocket(port: port, path: "/ws/lobby") { inbound, outbound in
                var iterator = inbound.makeAsyncIterator()

                let welcome = try await iterator.next()
                #expect(welcome.flatMap(self.text) == "joined lobby")

                try await outbound.write(self.maskedText("hi"))
                let echo = try await iterator.next()
                #expect(echo.flatMap(self.text) == "echo: hi")
            }
        }
    }

    @Test func pingIsAutoPonged() async throws {
        try await withRunningServer { port in
            try await withWebSocket(port: port, path: "/ws/lobby") { inbound, outbound in
                var iterator = inbound.makeAsyncIterator()
                _ = try await iterator.next()  // welcome

                try await outbound.write(
                    WebSocketFrame(
                        fin: true,
                        opcode: .ping,
                        maskKey: WebSocketMaskingKey([1, 2, 3, 4]),
                        data: ByteBuffer(string: "marco")
                    )
                )
                let pong = try await iterator.next()
                #expect(pong?.opcode == .pong)
                var pongData = pong?.unmaskedData ?? ByteBuffer()
                #expect(pongData.readString(length: pongData.readableBytes) == "marco")
            }
        }
    }

    @Test func serverInitiatedCloseCompletesHandshake() async throws {
        try await withRunningServer { port in
            try await withWebSocket(port: port, path: "/ws/lobby") { inbound, outbound in
                var iterator = inbound.makeAsyncIterator()
                _ = try await iterator.next()  // welcome

                try await outbound.write(self.maskedText("please close"))
                let close = try await iterator.next()
                #expect(close?.opcode == .connectionClose)
                var data = close?.unmaskedData ?? ByteBuffer()
                #expect(data.readInteger(as: UInt16.self) == 1000)
            }
        }
    }

    @Test func fragmentedMessageIsReassembled() async throws {
        try await withRunningServer { port in
            try await withWebSocket(port: port, path: "/ws/lobby") { inbound, outbound in
                var iterator = inbound.makeAsyncIterator()
                _ = try await iterator.next()  // welcome

                try await outbound.write(WebSocketFrame(
                    fin: false, opcode: .text,
                    maskKey: WebSocketMaskingKey([9, 9, 9, 9]),
                    data: ByteBuffer(string: "frag")
                ))
                try await outbound.write(WebSocketFrame(
                    fin: true, opcode: .continuation,
                    maskKey: WebSocketMaskingKey([7, 7, 7, 7]),
                    data: ByteBuffer(string: "mented")
                ))
                let echo = try await iterator.next()
                #expect(echo.flatMap(self.text) == "echo: fragmented")
            }
        }
    }
}
