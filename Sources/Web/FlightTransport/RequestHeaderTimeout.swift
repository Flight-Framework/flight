import Logging
import HummingbirdCore
import NIOCore

/// Closes a connection that never finishes sending its first request head.
///
/// HummingbirdCore has its own idle timeout and Flight configures it, but the
/// upgrade channel installs that handler from its *not-upgrading completion
/// handler* — which does not run until a request head has decoded. So it
/// bounds an idle keep-alive connection and a request that stalls after its
/// head, and it cannot see the connection that stalls *before* its first head
/// is complete. That is the slowloris shape exactly: open many connections,
/// trickle a byte occasionally, never finish a header block. Each one was
/// held until the OS gave up, roughly four minutes.
///
/// This is nginx's `client_header_timeout`, and it is a different bound from
/// an idle timeout in the way that matters: it **disarms the moment the header
/// terminator arrives**, so a long upload, a long download, an SSE stream and
/// an upgraded WebSocket are all untouched by it however long they run. That
/// is what makes it safe to have on by default.
///
/// Only the first head needs covering. Everything after it — the gap between
/// keep-alive requests, and a second head that stalls — is already
/// `HTTPConnectionStateHandler`'s, which by then is in the pipeline.
final class RequestHeaderTimeoutHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    private let timeout: TimeAmount
    private let logger: Logger
    private var scheduled: Scheduled<Void>?
    private var isDisarmed = false

    /// Up to three bytes carried from the previous read, so a terminator
    /// split across two packets is still seen. Splitting it is precisely what
    /// a slowloris client does, so this is the case rather than the corner.
    private var carry: [UInt8] = []

    init(timeout: TimeAmount, logger: Logger) {
        self.timeout = timeout
        self.logger = logger
    }

    func handlerAdded(context: ChannelHandlerContext) {
        if context.channel.isActive { arm(context) }
    }

    func channelActive(context: ChannelHandlerContext) {
        arm(context)
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !isDisarmed else {
            context.fireChannelRead(data)
            return
        }
        if sawHeaderTerminator(unwrapInboundIn(data)) {
            disarm()
        }
        context.fireChannelRead(data)
    }

    func channelInactive(context: ChannelHandlerContext) {
        disarm()
        context.fireChannelInactive()
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        disarm()
    }

    private func arm(_ context: ChannelHandlerContext) {
        guard scheduled == nil, !isDisarmed else { return }
        let loop = context.eventLoop
        scheduled = loop.assumeIsolatedUnsafeUnchecked().scheduleTask(in: timeout) {
            self.logger.debug(
                "closing connection that never completed a request head",
                metadata: ["timeout": "\(self.timeout)"])
            context.close(promise: nil)
        }
    }

    /// Stops the timer and stops scanning.
    ///
    /// The handler stays in the pipeline rather than removing itself
    /// mid-`channelRead`: removal from inside a read is a race worth not
    /// having for the sake of one branch per read on a connection that has
    /// already proven it speaks HTTP.
    private func disarm() {
        isDisarmed = true
        carry = []
        scheduled?.cancel()
        scheduled = nil
    }

    /// Whether the end of a header block has gone past.
    ///
    /// `\r\n\r\n` per RFC 9112, and bare `\n\n` too — NIO's decoder accepts
    /// LF-only line endings, and a bound that a lenient client can slip past
    /// is not a bound.
    private func sawHeaderTerminator(_ buffer: ByteBuffer) -> Bool {
        var window = carry
        window.append(contentsOf: buffer.readableBytesView)
        defer { carry = Array(window.suffix(3)) }

        guard window.count >= 2 else { return false }
        for index in 0..<(window.count - 1) {
            if window[index] == 0x0A, window[index + 1] == 0x0A { return true }
            if index + 3 < window.count,
                window[index] == 0x0D, window[index + 1] == 0x0A,
                window[index + 2] == 0x0D, window[index + 3] == 0x0A
            {
                return true
            }
        }
        return false
    }
}

/// Installs ``RequestHeaderTimeoutHandler`` in front of a child channel.
///
/// A wrapper rather than an entry in `HTTP1Channel.Configuration
/// .additionalChannelHandlers`, because those are added from the same
/// completion handler as the idle handler — after a head has decoded, which
/// is after the window this bounds has already closed.
struct HeaderTimeoutChildChannel<Wrapped: ServerChildChannel>: ServerChildChannel {
    typealias Value = Wrapped.Value

    let wrapped: Wrapped
    let timeout: TimeAmount

    func setup(channel: any Channel, logger: Logger) -> EventLoopFuture<Value> {
        channel.eventLoop.makeCompletedFuture {
            // Added before the wrapped channel's own handlers, so it sees
            // raw request bytes. Under TLS the NIOSSL handler is added by an
            // outer wrapper and is therefore still ahead of this one — these
            // are decrypted bytes, which is the only thing worth scanning.
            try channel.pipeline.syncOperations.addHandler(
                RequestHeaderTimeoutHandler(timeout: timeout, logger: logger))
        }
        .flatMap { wrapped.setup(channel: channel, logger: logger) }
    }

    func handle(value: Value, logger: Logger) async {
        await wrapped.handle(value: value, logger: logger)
    }
}
