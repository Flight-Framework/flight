import FlightChannels
import FlightChannelsClient
import FlightChannelsTesting
import FlightCore
import FlightPubSub
import FlightWeb
import FlightWebTesting
import Foundation
import Synchronization

/// Server-side fixture the client suite talks to — a real Flight stack
/// (module wiring, upgrade pipeline, PubSub), in process.
struct CounterChannel: Channel {
    let broadcaster: ChannelBroadcaster

    func join(_ topic: String, socket: Socket) async -> JoinResult {
        if topic == "counter:locked" { return .reject(.forbidden) }
        return .ok(initialState: ["count": 0])
    }

    func handle(_ event: InboundEvent, socket: Socket) async -> HandleResult {
        switch event.event {
        case "echo":
            return .reply(event.payload)
        case "announce":
            await broadcaster.broadcast(topic: event.topic, event: "announced", payload: event.payload)
            return .reply(["sent": true])
        case "announce_quietly":
            await broadcaster.broadcast(topic: event.topic, event: "announced", payload: event.payload)
            return .none
        case "silent":
            return .none
        case "fail":
            return .error(reason: "nope")
        default:
            return .none
        }
    }
}

struct ClientFixtureModule: FlightModule {
    static var dependencies: [any FlightModule.Type] { [FlightChannelsModule.self] }

    func configure(_ container: Container) throws {
        container.registerChannel("counter:*") { container in
            CounterChannel(broadcaster: try container.resolve(ChannelBroadcaster.self))
        }
        container.registerChannelSocket("/socket")
    }
}

struct ClientHarness {
    let container: Container
    let testClient: TestClient
    let transport: any ChannelClientTransport

    init(
        heartbeatTimeoutSeconds: Double = 5,
        transportDecorator: (any ChannelClientTransport) -> any ChannelClientTransport = { $0 }
    ) throws {
        let configuration = Configuration(values: [
            "flight.channels.heartbeat-timeout-seconds": "\(heartbeatTimeoutSeconds)",
            "flight.channels.heartbeat-check-interval-seconds": "0.03",
        ])
        self.container = try TestContainer.build(configuration: configuration) {
            ClientFixtureModule()
        }
        self.testClient = try TestClient(container: container)
        self.transport = transportDecorator(InMemoryChannelTransport(testClient: testClient))
    }

    func makeClient(
        configuration: ChannelClientConfiguration = ChannelClientConfiguration()
    ) -> ChannelClient {
        ChannelClient(
            url: URL(string: "flight-test:///socket")!,
            transport: transport,
            configuration: configuration
        )
    }
}

/// Wraps a transport so tests can sever the live connection (simulating a
/// network drop the server never gets to announce) and count dials.
final class SeverableTransport: ChannelClientTransport, Sendable {
    struct Severed: Error {}

    private let wrapped: any ChannelClientTransport
    private let state = Mutex<(connects: Int, severs: [@Sendable () -> Void], refuseNext: Int)>((0, [], 0))

    init(wrapping transport: any ChannelClientTransport) {
        self.wrapped = transport
    }

    var connectCount: Int {
        state.withLock { $0.connects }
    }

    /// Makes the next `count` dials fail — exercising backoff retries.
    func refuseNextConnects(_ count: Int) {
        state.withLock { $0.refuseNext = count }
    }

    /// Tears down every live connection abruptly: the incoming stream
    /// throws, in-flight sends fail.
    func severAll() {
        let severs = state.withLock { state in
            let s = state.severs
            state.severs = []
            return s
        }
        for sever in severs { sever() }
    }

    func connect(to url: URL) async throws -> ClientTransportConnection {
        let refused: Bool = state.withLock { state in
            state.connects += 1
            if state.refuseNext > 0 {
                state.refuseNext -= 1
                return true
            }
            return false
        }
        if refused { throw Severed() }

        let underlying = try await wrapped.connect(to: url)
        let alive = Mutex(true)
        let (incoming, continuation) = AsyncThrowingStream<String, any Error>.makeStream()
        let pump = Task {
            do {
                for try await text in underlying.incoming {
                    continuation.yield(text)
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        state.withLock { state in
            state.severs.append {
                alive.withLock { $0 = false }
                pump.cancel()
                continuation.finish(throwing: Severed())
                Task { await underlying.close() }
            }
        }
        return ClientTransportConnection(
            incoming: incoming,
            send: { text in
                guard alive.withLock({ $0 }) else { throw Severed() }
                try await underlying.send(text)
            },
            close: {
                await underlying.close()
                continuation.finish()
            }
        )
    }
}

/// Waits (bounded) for an async condition — client state machines settle in
/// milliseconds, but not synchronously.
func eventually(
    within: Duration = .seconds(2),
    _ condition: @Sendable () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + within
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}
