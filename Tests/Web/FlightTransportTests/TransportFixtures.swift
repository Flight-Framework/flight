import FlightCore
import FlightTransport
import FlightWeb
import FlightWebTesting
import Foundation
import Synchronization
import Testing

// MARK: - Fixture app (macros end-to-end, served over a real socket)

@Controller
struct WireController {
    @GetMapping("/hello")
    func hello(_ context: RequestContext) -> String {
        "hello"
    }

    @PostMapping("/echo")
    func echo(_ context: RequestContext, body: EchoBody) throws -> EchoBody {
        body
    }

    @GetMapping("/sse")
    func sse(_ context: RequestContext) -> Response {
        .serverSentEvents { events in
            events.send(data: "first", event: "tick")
            try? await Task.sleep(for: .milliseconds(50))
            events.send(data: "second", event: "tick")
        }
    }

    /// Records that its body ran. An upgrade-shaped request at this ordinary
    /// HTTP route must leave the counter at zero.
    @GetMapping("/counted")
    func counted(_ context: RequestContext) -> String {
        WireSideEffect.count.withLock { $0 += 1 }
        return "counted"
    }

    @WebSocketMapping("/ws/:room")
    func socket(_ context: RequestContext) -> any WebSocketUpgradeHandler {
        WireEchoHandler(room: context.pathParam("room") ?? "?")
    }
}

struct EchoBody: Codable, Equatable, ResponseEncodable {
    let name: String
}

struct WireEchoHandler: WebSocketUpgradeHandler {
    let room: String

    func handle(upgraded connection: WebSocketConnection, context: RequestContext) async throws {
        try await connection.send("joined \(room)")
        for await frame in connection.frames {
            switch frame {
            case .text(let text):
                if text == "please close" {
                    try await connection.close(code: .normalClosure, reason: "as requested")
                    return
                }
                try await connection.send("echo: \(text)")
            case .close:
                return
            default:
                continue
            }
        }
    }
}

enum WireSideEffect {
    nonisolated(unsafe) static let count = Mutex(0)
    static func reset() { count.withLock { $0 = 0 } }
}

struct WireModule: FlightModule {
    func configure(_ container: Container) throws {
        try WireController._flightRegister(container)
    }
}

// MARK: - Server harness

/// Boots a `FlightTransport` on an ephemeral port with the fixture app,
/// hands the bound port to `body`, and tears the server down afterwards.
func withRunningServer(
    maxRequestBodyBytes: Int = 1 << 20,
    tls: FlightTransportConfiguration.TLS? = nil,
    _ body: @escaping @Sendable (_ port: Int) async throws -> Void
) async throws {
    let container = try TestContainer.build { WireModule() }
    let dispatch = try TestClient(container: container).dispatch

    let (portStream, portContinuation) = AsyncStream<Int>.makeStream()
    let configuration = FlightTransportConfiguration(
        host: "127.0.0.1",
        port: 0,
        maxRequestBodyBytes: maxRequestBodyBytes,
        tls: tls,
        onBound: { port in portContinuation.yield(port) }
    )
    let transport = FlightTransport(configuration: configuration, dispatch: dispatch)

    let server = Task {
        try await transport.run()
    }
    defer { server.cancel() }

    var boundPort: Int? = nil
    for await port in portStream {
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
