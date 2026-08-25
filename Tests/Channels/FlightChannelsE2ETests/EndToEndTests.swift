import FlightChannels
import FlightChannelsClient
import FlightCore
import FlightPubSub
import FlightTransport
import FlightWeb
import FlightWebTesting
import Foundation
import HummingbirdWSClient
import Logging
import Testing

// MARK: - A real transport for the reference client
//
// The shipped client is deliberately transport-free; this is the "real
// socket" adapter an app would write (or a future FlightChannelsTransport
// target would ship) — hummingbird's WSClient bridged into the
// `ChannelClientTransport` seam in ~60 lines.

struct NIOWebSocketTransport: ChannelClientTransport {
    struct HandshakeFailed: Error {}

    func connect(to url: URL) async throws -> ClientTransportConnection {
        let (incoming, incomingContinuation) = AsyncThrowingStream<String, any Error>.makeStream()
        let (outgoing, outgoingContinuation) = AsyncStream<String>.makeStream()
        let (ready, readyContinuation) = AsyncStream<Void>.makeStream()

        var logger = Logger(label: "e2e.ws-client")
        logger.logLevel = .critical

        let session = Task {
            do {
                try await WebSocketClient.connect(url: url.absoluteString, logger: logger) { inbound, outbound, _ in
                    readyContinuation.yield(())
                    readyContinuation.finish()
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask {
                            var iterator = inbound.makeAsyncIterator()
                            while let message = try await iterator.nextMessage(maxSize: 1 << 20) {
                                if case .text(let text) = message {
                                    incomingContinuation.yield(text)
                                }
                            }
                        }
                        group.addTask {
                            for await text in outgoing {
                                try await outbound.write(.text(text))
                            }
                        }
                        _ = try await group.next()
                        group.cancelAll()
                    }
                }
                incomingContinuation.finish()
            } catch {
                incomingContinuation.finish(throwing: error)
            }
            readyContinuation.finish()
        }

        var readiness = ready.makeAsyncIterator()
        guard await readiness.next() != nil else {
            session.cancel()
            throw HandshakeFailed()
        }

        return ClientTransportConnection(
            incoming: incoming,
            send: { text in outgoingContinuation.yield(text) },
            close: {
                outgoingContinuation.finish() // ends the write loop → close handshake
                session.cancel()
            }
        )
    }
}

// MARK: - Server fixture

struct WireChannel: Channel {
    let broadcaster: ChannelBroadcaster

    func join(_ topic: String, socket: Socket) async -> JoinResult {
        .ok(initialState: ["joined": .string(topic)])
    }

    func handle(_ event: InboundEvent, socket: Socket) async -> HandleResult {
        switch event.event {
        case "echo":
            return .reply(event.payload)
        case "announce":
            await broadcaster.broadcast(topic: event.topic, event: "announced", payload: event.payload)
            return .reply(["sent": true])
        default:
            return .none
        }
    }
}

struct E2EModule: FlightModule {
    static var dependencies: [any FlightModule.Type] { [FlightChannelsModule.self] }

    func configure(_ container: Container) throws {
        container.registerChannel("wire:*") { container in
            WireChannel(broadcaster: try container.resolve(ChannelBroadcaster.self))
        }
        container.registerChannelSocket("/socket")
    }
}

/// Boots a real `FlightTransport` on an ephemeral port with the channels
/// stack, hands the bound port to `body`, tears the server down after.
func withRunningChannelServer(
    _ body: @escaping @Sendable (_ port: Int) async throws -> Void
) async throws {
    let container = try TestContainer.build { E2EModule() }
    let dispatch = try TestClient(container: container).dispatch

    let (ports, portContinuation) = AsyncStream<Int>.makeStream()
    let transport = FlightTransport(
        configuration: FlightTransportConfiguration(
            host: "127.0.0.1",
            port: 0,
            onBound: { port in portContinuation.yield(port) }
        ),
        dispatch: dispatch
    )
    let server = Task { try await transport.run() }
    defer { server.cancel() }

    var boundPort: Int?
    for await port in ports {
        boundPort = port
        break
    }
    guard let port = boundPort else {
        Issue.record("server never bound")
        return
    }
    try await body(port)
    server.cancel()
    _ = try? await server.value
}

// MARK: - Tests

@Suite("End to end over a real socket", .timeLimit(.minutes(2)))
struct EndToEndTests {

    private func makeClient(port: Int, heartbeat: Duration = .seconds(25)) -> ChannelClient {
        ChannelClient(
            url: URL(string: "ws://127.0.0.1:\(port)/socket")!,
            transport: NIOWebSocketTransport(),
            configuration: ChannelClientConfiguration(heartbeatInterval: heartbeat)
        )
    }

    @Test("two real clients share a room through the full stack")
    func broadcastOverTCP() async throws {
        try await withRunningChannelServer { port in
            let alice = makeClient(port: port)
            let bob = makeClient(port: port)
            try await alice.connect()
            try await bob.connect()

            let aliceRoom = alice.channel("wire:42")
            let bobRoom = bob.channel("wire:42")
            let joined = try await aliceRoom.join()
            #expect(joined == ["joined": "wire:42"])
            try await bobRoom.join()
            let bobMessages = await bobRoom.messages()

            let reply = try await aliceRoom.push("announce", payload: ["body": "over TCP"])
            #expect(reply == ["sent": true])

            var iterator = bobMessages.makeAsyncIterator()
            let message = await iterator.next()
            #expect(message == ChannelMessage(event: "announced", payload: ["body": "over TCP"]))

            await alice.disconnect()
            await bob.disconnect()
        }
    }

    @Test("request/reply and heartbeats over a real connection")
    func echoAndHeartbeat() async throws {
        try await withRunningChannelServer { port in
            // Aggressive heartbeat so several land during the test.
            let client = makeClient(port: port, heartbeat: .milliseconds(80))
            try await client.connect()
            let room = client.channel("wire:1")
            try await room.join()

            try await Task.sleep(for: .milliseconds(400))
            #expect(await client.connectionState == .connected)

            let reply = try await room.push("echo", payload: ["n": 7, "nested": ["deep": true]])
            #expect(reply == ["n": 7, "nested": ["deep": true]])
            await client.disconnect()
        }
    }
}
