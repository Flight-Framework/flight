import FlightChannelsClient
import FlightWeb
import FlightWebTesting
import struct Foundation.URL

/// A `ChannelClientTransport` that "dials" Flight Web's in-process upgrade
/// pipeline (`TestClient.webSocket`) instead of a network: the full stack —
/// routing, the upgrade handshake, `ChannelSocketHandler`, PubSub — with
/// zero sockets. Every `connect(to:)` dispatches a fresh upgrade request,
/// so client reconnection is exercised for real: a new server-side session,
/// rejoins and all.
///
///     let container = try TestContainer.build { AppModule() }
///     let transport = InMemoryChannelTransport(testClient: try TestClient(container: container))
///     let client = ChannelClient(url: URL(string: "flight-test:///socket")!, transport: transport)
///
/// The URL's path selects the route ("/socket" for the default mount); the
/// scheme/host are ignored.
public struct InMemoryChannelTransport: ChannelClientTransport {
    private let testClient: TestClient
    /// Query appended to the upgrade request — how tests exercise
    /// upgrade-time authentication ("token=..." etc.).
    private let query: String?

    public init(testClient: TestClient, query: String? = nil) {
        self.testClient = testClient
        self.query = query
    }

    public func connect(to url: URL) async throws -> ClientTransportConnection {
        var path = url.path.isEmpty ? "/socket" : url.path
        if let query = query ?? url.query {
            path += "?\(query)"
        }
        let socket = try await testClient.webSocket(path)

        let (incoming, continuation) = AsyncThrowingStream<String, any Error>.makeStream()
        let pump = Task {
            for await frame in socket.frames {
                switch frame {
                case .text(let text):
                    continuation.yield(text)
                case .close:
                    continuation.finish()
                    return
                case .binary, .ping, .pong:
                    continue
                }
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in pump.cancel() }

        return ClientTransportConnection(
            incoming: incoming,
            send: { text in socket.send(text) },
            close: { socket.close() }
        )
    }
}
