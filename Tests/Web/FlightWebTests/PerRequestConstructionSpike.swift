import FlightCore
import FlightWebTesting
import Foundation
import HTTPTypes
import Synchronization
import Testing

@testable import FlightWeb

/// Work-plan step 6, spiked before 51 route terminals commit to the shape.
///
/// The target (COMPOSITION-MIGRATION.md §2.1a) is a generated route terminal
/// that constructs the request's controller instead of resolving one: process
/// dependencies from a `FlightGraph`, request values from the context, and
/// nothing looked up by type. Today `@Controller` resolves the controller
/// once at `freeze()` and the handler closure captures it, so every request
/// shares an instance.
///
/// What this pins is the part the plan says to prove first: a response that
/// outlives the dispatch call which produced it, when the thing that produced
/// it was built per request. Streaming and upgrade are the two cases that
/// killed the earlier closure-scoped design, and they are the two here.
///
/// `SpikeGraph` stands in for the generated struct — hand-written so the
/// shape is legible, and deliberately holding only what a real one would.
@Suite("Per-request construction (step 6 spike)", .serialized)
struct PerRequestConstructionSpike {

    @Test("a controller is constructed per request, not shared across them")
    func constructedPerRequest() async throws {
        Instances.reset()
        let client = try TestClient(container: TestContainer.build { SpikeModule() })

        _ = await client.get("/spike/plain")
        _ = await client.get("/spike/plain")

        // Two requests, two controllers. Under the resolving shape this
        // would be one: the container hands back the same singleton, and the
        // handler closure captured it before the first request even arrived.
        #expect(Instances.count == 2)
    }

    @Test("the controller sees what the middleware above it contributed")
    func seesUpstreamContribution() async throws {
        // The reason construction belongs in the terminal rather than at
        // registration: the terminal is the innermost layer, so every
        // middleware has already handed its copy of the context downstream.
        // A controller built at freeze() cannot take a request value at all.
        Instances.reset()
        let client = try TestClient(container: TestContainer.build { SpikeModule() })
        let response = await client.get("/spike/plain", headers: tenantHeader)
        #expect(response.bodyText == "tenant=acme")
    }

    @Test("a streaming body outlives dispatch and still completes")
    func streamingOutlivesDispatch() async throws {
        // The response is produced by a controller that no longer exists as
        // far as dispatch is concerned — the terminal returned, and the
        // producer closure is what holds it. Ordinary Swift lifetime, and
        // safe only because §2.12 keeps leases out of entry points: nothing
        // the terminal built owns a pooled resource.
        Instances.reset()
        let client = try TestClient(container: TestContainer.build { SpikeModule() })
        let response = await client.get("/spike/stream", headers: tenantHeader)
        let body = await response.collectStreamingBody()
        #expect(String(decoding: body, as: UTF8.self) == "acme:0acme:1acme:2")
        #expect(Instances.count == 1)
    }

    @Test("an upgraded socket outlives dispatch and still serves")
    func upgradeOutlivesDispatch() async throws {
        // The hardest case: the handler is built per request during the
        // upgrade, and then lives as long as the socket — far past the
        // dispatch call that made it.
        Instances.reset()
        let client = try TestClient(container: TestContainer.build { SpikeModule() })
        let socket = try await client.webSocket("/spike/socket", headers: tenantHeader)

        var received: [String] = []
        socket.send("ping")
        for await frame in socket.frames {
            if case .text(let text) = frame {
                received.append(text)
                if received.count == 2 { socket.close() }
            }
            if received.count == 2 { break }
        }
        #expect(received == ["hello acme", "acme heard ping"])
        await socket.waitForServer()
    }
}

// MARK: - The shape under test

/// Stand-in for the generated composition function: process-lifetime
/// components, built once.
private struct SpikeGraph: Sendable {
    let greeting: String
}

/// Stand-in for a generated controller. Its dependencies arrive as
/// initializer arguments — one from the graph, one from the request — which
/// is the whole point: nothing is resolved by type, so nothing can be
/// resolved that was not declared.
private struct SpikeController: Sendable {
    let greeting: String
    let tenant: String

    init(greeting: String, tenant: String) {
        self.greeting = greeting
        self.tenant = tenant
        Instances.record()
    }

    func plain() -> Response { .text("tenant=\(tenant)") }

    func stream() -> Response {
        // Captures `self`, so the controller outlives the terminal.
        .streaming(contentType: .text) { emit in
            for index in 0..<3 {
                await emit.write(Data("\(tenant):\(index)".utf8))
            }
        }
    }

    func socket(_ context: RequestContext) -> Response {
        .upgrade(handler: SpikeSocket(greeting: greeting, tenant: tenant), context: context)
    }
}

private struct SpikeSocket: WebSocketUpgradeHandler {
    let greeting: String
    let tenant: String

    func handle(upgraded connection: WebSocketConnection, context: RequestContext) async throws {
        try await connection.send("\(greeting) \(tenant)")
        for await frame in connection.frames {
            if case .text(let text) = frame {
                try await connection.send("\(tenant) heard \(text)")
            }
        }
    }
}

/// Registers the three routes by hand, each terminal doing what a generated
/// one would: build the controller, then call it.
private struct SpikeModule: FlightModule {
    func configure(_ container: Container) throws {
        let graph = SpikeGraph(greeting: "hello")

        // flight:hand-registered — the spike *is* hand-registered dispatch;
        // the point is the shape of the closure body, not how it got there.
        container.registerRoute(.get, "/spike/plain", source: "spike") { context in
            SpikeController(greeting: graph.greeting, tenant: tenant(of: context)).plain()
        }
        // flight:hand-registered — same.
        container.registerRoute(.get, "/spike/stream", source: "spike") { context in
            SpikeController(greeting: graph.greeting, tenant: tenant(of: context)).stream()
        }
        // flight:hand-registered — same.
        container.registerRoute(
            .get, "/spike/socket", kind: .upgrade(.webSocket), source: "spike"
        ) { context in
            SpikeController(greeting: graph.greeting, tenant: tenant(of: context)).socket(context)
        }
    }
}

private func tenant(of context: RequestContext) -> String {
    context.request.headers[HTTPField.Name("x-tenant")!] ?? "?"
}

/// One header, built once — `HTTPFields` is keyed by `HTTPField.Name`.
private let tenantHeader: HTTPFields = {
    var headers = HTTPFields()
    headers[HTTPField.Name("x-tenant")!] = "acme"
    return headers
}()

/// How many controllers were built. A counter rather than a timing
/// measurement: what matters here is the lifetime, and construction is field
/// copies of references already in hand.
private enum Instances {
    private static let value = Mutex(0)
    static func reset() { value.withLock { $0 = 0 } }
    static func record() { value.withLock { $0 += 1 } }
    static var count: Int { value.withLock { $0 } }
}
