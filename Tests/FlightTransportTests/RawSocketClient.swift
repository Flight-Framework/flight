import Foundation
import NIOCore
import NIOPosix

/// A deliberately dumb TCP client: writes raw bytes, accumulates raw bytes.
/// Dumb is the point — it lets tests assert on the exact wire format
/// (status lines, chunked framing, keep-alive behavior) with no client-side
/// HTTP machinery interpreting anything first.
final class RawSocketClient {

    final class Session {
        private var inboundIterator: NIOAsyncChannelInboundStream<ByteBuffer>.AsyncIterator
        private let outbound: NIOAsyncChannelOutboundWriter<ByteBuffer>
        private var received = ""

        init(
            inbound: NIOAsyncChannelInboundStream<ByteBuffer>,
            outbound: NIOAsyncChannelOutboundWriter<ByteBuffer>
        ) {
            self.inboundIterator = inbound.makeAsyncIterator()
            self.outbound = outbound
        }

        func send(_ text: String) async throws {
            try await outbound.write(ByteBuffer(string: text))
        }

        /// Accumulates inbound bytes until `marker` appears (returning
        /// everything read so far) or the connection closes.
        @discardableResult
        func readUntil(_ marker: String) async throws -> String {
            while !received.contains(marker) {
                guard let buffer = try await inboundIterator.next() else { break }
                received += String(buffer: buffer)
            }
            return received
        }

        /// Reads to connection close, returning the full transcript.
        func readToEnd() async throws -> String {
            while let buffer = try await inboundIterator.next() {
                received += String(buffer: buffer)
            }
            return received
        }

        var transcript: String { received }
    }

    /// Connects, runs `body` with a session, closes.
    static func withConnection(
        port: Int,
        _ body: (Session) async throws -> Void
    ) async throws {
        let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .connect(host: "127.0.0.1", port: port) { channel in
                channel.eventLoop.makeCompletedFuture {
                    try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: channel)
                }
            }
        try await channel.executeThenClose { inbound, outbound in
            try await body(Session(inbound: inbound, outbound: outbound))
        }
    }
}
