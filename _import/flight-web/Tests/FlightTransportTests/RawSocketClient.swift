import Foundation
import NIOCore
import NIOPosix
import NIOSSL

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

    /// Connects over TLS, runs `body` with a session, closes.
    ///
    /// `trustRootsPath` is the PEM the client verifies the server against —
    /// the test CA, not the system store, since the server certificate is
    /// generated per run. `clientCertificate`/`clientKey` present a client
    /// certificate, for the mutual-TLS case.
    static func withTLSConnection(
        port: Int,
        serverHostname: String? = "localhost",
        trustRootsPath: String,
        clientCertificatePath: String? = nil,
        clientKeyPath: String? = nil,
        _ body: (Session) async throws -> Void
    ) async throws {
        var tls = TLSConfiguration.makeClientConfiguration()
        tls.trustRoots = .certificates(try NIOSSLCertificate.fromPEMFile(trustRootsPath))
        if let clientCertificatePath, let clientKeyPath {
            tls.certificateChain = try NIOSSLCertificate.fromPEMFile(clientCertificatePath)
                .map { .certificate($0) }
            tls.privateKey = .privateKey(
                try NIOSSLPrivateKey(file: clientKeyPath, format: .pem))
        }
        let context = try NIOSSLContext(configuration: tls)

        let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .connect(host: "127.0.0.1", port: port) { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(
                        NIOSSLClientHandler(context: context, serverHostname: serverHostname))
                    return try NIOAsyncChannel<ByteBuffer, ByteBuffer>(
                        wrappingChannelSynchronously: channel)
                }
            }
        try await channel.executeThenClose { inbound, outbound in
            try await body(Session(inbound: inbound, outbound: outbound))
        }
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
