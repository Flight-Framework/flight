import FlightChannelsProtocol
import FlightCore
import FlightPubSub
import FlightWeb
import Logging

/// Channels' `WebSocketUpgradeHandler`: owns one upgraded WebSocket
/// for its lifetime — decoding frames, routing them through a
/// `SocketSession` to per-topic `Channel`s, writing everything outbound
/// through one serialized writer, and enforcing heartbeat liveness.
///
/// One instance per connection: the route handler constructs it during the
/// upgrade request, which is where per-connection identity (the principal,
///) enters. Constructed for you by `Container.registerChannelSocket`, or
/// directly from a `@WebSocketMapping` method via `init(context:principal:)`.
public struct ChannelSocketHandler: WebSocketUpgradeHandler {
    private let router: ChannelRouter
    private let pubsub: any PubSub
    private let configuration: ChannelsConfiguration
    private let principal: (any ChannelPrincipal)?

    public init(
        router: ChannelRouter,
        pubsub: any PubSub,
        configuration: ChannelsConfiguration,
        principal: (any ChannelPrincipal)? = nil
    ) {
        self.router = router
        self.pubsub = pubsub
        self.configuration = configuration
        self.principal = principal
    }

    /// Resolves the channels components from the request's context — the
    /// convenience for a hand-written `@WebSocketMapping` method:
    ///
    ///     @WebSocketMapping("/socket")
    ///     func socket(_ context: RequestContext) throws -> any WebSocketUpgradeHandler {
    ///         try ChannelSocketHandler(context: context, principal: myPrincipal(context))
    ///     }
    public init(context: RequestContext, principal: (any ChannelPrincipal)? = nil) throws {
        self.init(
            router: try context.resolve(ChannelRouter.self),
            pubsub: try context.resolve((any PubSub).self),
            configuration: try context.resolve(ChannelsConfiguration.self),
            principal: principal
        )
    }

    public func handle(upgraded connection: WebSocketConnection, context: RequestContext) async throws {
        // Bounded: an unbounded queue lets one client that stopped reading
        // grow without limit until the server runs out of memory.
        //
        // Carries pre-encoded text, not `Envelope` values: `Socket.enqueue`
        // encodes single-target sends, and `SocketSession.pump` forwards
        // `ChannelBroadcaster`'s precomputed frame directly — so encoding
        // has already happened by the time anything reaches this queue, and
        // the writer below is pure I/O.
        let (outbound, outboundContinuation) = AsyncStream<String>.makeStream(
            bufferingPolicy: .bufferingNewest(configuration.outboundBufferSize))
        let socket = Socket(
            principal: principal,
            logger: context.logger,
            outbound: outboundContinuation
        )
        let session = SocketSession(
            router: router,
            pubsub: pubsub,
            socket: socket,
            outbound: outboundContinuation,
            logger: context.logger
        )
        context.logger.debug("channel socket opened", metadata: [
            "socket": "\(socket.id)",
            "principal": "\(principal?.subject ?? "<anonymous>")",
        ])

        // Three tasks per connection, all owned by this call and joined
        // before it returns — the socket's whole session lives under its
        // request `Scope`:
        //
        // - writer: drains the one outbound queue to the transport. The
        //   queue finishing (teardown does that) is its normal exit; a send
        //   failure (peer gone mid-write) an early one.
        // - watchdog: closes sockets that go silent past the heartbeat
        //   timeout.
        // - frame loop: reads, decodes, routes — strictly one envelope at a
        //   time, preserving per-socket message order end to end.
        //
        // Exit coordination cannot rely on the transport finishing the
        // frame stream after a *server-initiated* close: the half-open
        // connection (the case heartbeats exist for) never acknowledges the
        // close handshake. So both the writer and the frame loop announce
        // their exit on `finished`; whichever fires first, the handler
        // cancels the frame loop (AsyncStream iteration is
        // cancellation-aware), tears down idempotently, drains the writer,
        // and joins everything.
        let (finished, finishedContinuation) = AsyncStream<Void>.makeStream()

        let writer = Task { [configuration] in
            for await text in outbound {
                do {
                    try await Self.send(text, over: connection, within: configuration.writeTimeout)
                } catch is WriteTimedOut {
                    // A peer that cannot take one frame in this long is not
                    // going to take the next. The heartbeat watchdog cannot
                    // catch this one: it counts *inbound* frames as liveness,
                    // so a client that keeps heartbeating while never reading
                    // looks alive to it while the writer is parked forever.
                    context.logger.info(
                        "closing channel socket: peer did not accept a frame in time",
                        metadata: [
                            "socket": "\(socket.id)",
                            "timeout": "\(configuration.writeTimeout.map(String.init(describing:)) ?? "none")",
                        ])
                    break
                } catch {
                    break  // connection gone; remaining outbound is undeliverable
                }
            }
            finishedContinuation.yield(())
        }

        let watchdog = Task { [configuration] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: configuration.heartbeatCheckInterval)
                } catch {
                    return // cancelled: session ended first
                }
                if await session.idleDuration > configuration.heartbeatTimeout {
                    context.logger.info("closing silent channel socket", metadata: [
                        "socket": "\(socket.id)",
                    ])
                    // Teardown finishes the outbound queue → the writer
                    // drains and announces its exit → the handler unwinds.
                    await session.teardown()
                    // Awaited, like every graceful path: closing straight
                    // after teardown left queued frames racing the close
                    // frame, and ran `send` and `close` concurrently on a
                    // transport that does not promise that is safe. Harmless
                    // in practice — a peer this silent is not reading — but
                    // the deterministic-drain claim did not hold on this one
                    // path, which is the sort of exception that is true until
                    // the day it is not.
                    _ = await writer.value
                    try? await connection.close(
                        code: WebSocketCloseCode(ChannelCloseCode.heartbeatTimeout),
                        reason: "heartbeat timeout"
                    )
                    return
                }
            }
        }

        let frameLoop = Task {
            frames: for await frame in connection.frames {
                await session.touch()
                switch frame {
                case .text(let text):
                    let envelope: Envelope
                    do {
                        envelope = try Envelope(text: text)
                    } catch {
                        // Flight owns both clients: an undecodable
                        // frame is a bug or an attack, not a compatibility
                        // case. Close, with the protocol-violation code.
                        context.logger.warning("undecodable channel frame", metadata: [
                            "socket": "\(socket.id)", "error": "\(error)",
                        ])
                        await session.teardown()
                        await writer.value // flush anything already queued
                        try? await connection.close(
                            code: WebSocketCloseCode(ChannelCloseCode.protocolViolation),
                            reason: "invalid envelope"
                        )
                        break frames
                    }
                    if case .close(let code, let reason) = await session.handle(envelope) {
                        // Graceful close (flight:close): handle() already
                        // tore down and finished the outbound queue. Let
                        // the writer flush the close ack before the close
                        // frame goes out.
                        await writer.value
                        try? await connection.close(code: code, reason: reason)
                        break frames
                    }
                case .binary:
                    // JSON text frames only in v1; the binary codec is a
                    // documented later addition, negotiated, never
                    // sprung on a server.
                    await session.teardown()
                    await writer.value
                    try? await connection.close(
                        code: .unacceptableData,
                        reason: "binary frames are not part of protocol v1"
                    )
                    break frames
                case .close:
                    break frames // peer closed; stream finishes right after
                case .ping, .pong:
                    continue // transport already answered; counts as liveness
                }
            }
            finishedContinuation.yield(())
        }

        // First exit wins; then unwind deterministically. Teardown is
        // idempotent, so every path — peer close, flight:close, protocol
        // violation, heartbeat timeout, task cancellation on server
        // shutdown — runs `leave` for each joined channel exactly once.
        var firstExit = finished.makeAsyncIterator()
        _ = await firstExit.next()
        frameLoop.cancel()
        await frameLoop.value
        await session.teardown()
        watchdog.cancel()
        await writer.value
        await watchdog.value
        try? await connection.close(code: .normalClosure, reason: "")
        context.logger.debug("channel socket closed", metadata: ["socket": "\(socket.id)"])
    }
}

/// One outbound frame took longer than ``ChannelsConfiguration/writeTimeout``.
struct WriteTimedOut: Error {}

extension ChannelSocketHandler {
    /// Sends one frame, giving up after `timeout`.
    ///
    /// Through ``FlightCore/withFlightTimeout(_:throwing:_:)`` rather than a
    /// task group, for the reason that type is written down at length:
    /// `WebSocketConnection.send` is a *closure* any transport supplies, so
    /// nothing here can require it to respond to cancellation — and a group
    /// awaits its children at scope exit, so one that does not would hang
    /// this write despite the timeout. Exactly how `ClusteredPubSub`'s own
    /// broadcast timeout failed to bound anything.
    static func send(
        _ text: String, over connection: WebSocketConnection, within timeout: Duration?
    ) async throws {
        try await withFlightTimeout(timeout, throwing: WriteTimedOut()) {
            try await connection.send(text)
        }
    }
}
