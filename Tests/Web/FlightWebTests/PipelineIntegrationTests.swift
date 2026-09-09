// Middleware ordering and lane composition, driven through a real Dispatch via
// a value-based TestClient — the same routes and middleware a composition root
// hands FlightWebModule.

import FlightCore
import FlightWeb
import FlightWebTesting
import Foundation
import HTTPTypes
import Synchronization
import Testing

// MARK: - Fixtures

/// A plain reference type so several middleware instances share one trace.
final class TraceBox: Sendable {
    private let storage = Mutex<[String]>([])
    func append(_ name: String) { storage.withLock { $0.append(name) } }
    func reset() { storage.withLock { $0.removeAll() } }
    var entries: [String] { storage.withLock { $0 } }
}

private let sharedTrace = TraceBox()

@Middleware struct OrderA: Sendable {
    func handle(_ context: RequestContext, next: Next) async throws -> Response {
        sharedTrace.append("A"); return try await next(context)
    }
}
@Middleware struct OrderB: Sendable {
    func handle(_ context: RequestContext, next: Next) async throws -> Response {
        sharedTrace.append("B"); return try await next(context)
    }
}
@Middleware struct OrderC: Sendable {
    func handle(_ context: RequestContext, next: Next) async throws -> Response {
        sharedTrace.append("C"); return try await next(context)
    }
}
@Middleware struct FrameworkLayerOne: Sendable {
    func handle(_ context: RequestContext, next: Next) async throws -> Response {
        sharedTrace.append("framework-1"); return try await next(context)
    }
}
@Middleware struct FrameworkLayerTwo: Sendable {
    func handle(_ context: RequestContext, next: Next) async throws -> Response {
        sharedTrace.append("framework-2"); return try await next(context)
    }
}
@Middleware struct AppLayerOne: Sendable {
    func handle(_ context: RequestContext, next: Next) async throws -> Response {
        sharedTrace.append("app-1"); return try await next(context)
    }
}

private let pingRoute = RouteRegistration(
    method: "GET", path: "/ping", source: "PingController"
) { _ in .text("pong") }

@Suite("Middleware ordering and composition", .serialized)
struct PipelineIntegrationTests {

    @Test("declared order within one lane is preserved")
    func singleLaneOrder() async throws {
        sharedTrace.reset()
        let client = try TestClient(
            routes: [pingRoute],
            middleware: MiddlewareRegistration.lane(.default, [OrderA(), OrderB(), OrderC()]))
        #expect(await client.get("/ping").status == .ok)
        #expect(sharedTrace.entries == ["A", "B", "C"])
    }

    @Test("middleware from two modules concatenates in composition order")
    func crossModuleComposition() async throws {
        sharedTrace.reset()
        // The composition root concatenates a framework module's middleware
        // ahead of the application's — both framework entries run outermost,
        // in the order the framework declared them.
        let middleware =
            MiddlewareRegistration.lane(.default, [FrameworkLayerOne(), FrameworkLayerTwo()])
            + MiddlewareRegistration.lane(.default, [AppLayerOne()])
        let client = try TestClient(routes: [pingRoute], middleware: middleware)
        #expect(await client.get("/ping").status == .ok)
        #expect(sharedTrace.entries == ["framework-1", "framework-2", "app-1"])
    }
}

// MARK: - Lanes

/// Its own box: the two suites run concurrently with each other.
private let laneTrace = TraceBox()

@Middleware struct DefaultLaneMarker: Sendable {
    func handle(_ context: RequestContext, next: Next) async throws -> Response {
        laneTrace.append("default-lane"); return try await next(context)
    }
}
@Middleware struct BareLaneMarker: Sendable {
    func handle(_ context: RequestContext, next: Next) async throws -> Response {
        laneTrace.append("bare-lane"); return try await next(context)
    }
}
@Middleware struct AdminLaneMarker: Sendable {
    func handle(_ context: RequestContext, next: Next) async throws -> Response {
        laneTrace.append("admin-lane"); return try await next(context)
    }
}

/// A controller routed through a bare lane — the static-asset shape: the
/// default stack must never run for it.
@Controller(pipelines: ["bare"])
struct BareLaneController {
    @GetRoute("/bare")
    func bare(_ context: RequestContext) -> String { "bare" }
}

@Controller(pipelines: [.default, "admin"])
struct AdminController {
    @GetRoute("/admin")
    func admin(_ context: RequestContext) -> String { "admin" }
}

@Controller("/dash", pipelines: ["admin"])
struct RouteLaneController {
    @GetRoute("/inherits")
    func inherits(_ context: RequestContext) -> String { "inherits" }

    @GetRoute("/replaced", pipelines: ["bare"])
    func replaced(_ context: RequestContext) -> String { "replaced" }

    @GetRoute("/public", pipelines: [.public])
    func explicitlyPublic(_ context: RequestContext) -> String { "public" }
}

@Suite("pipeline lanes", .serialized)
struct PipelineLaneTests {
    /// The lanes and routes a composition root would hand FlightWebModule.
    private func client() throws -> TestClient {
        let middleware =
            MiddlewareRegistration.lane(.default, [DefaultLaneMarker()])
            + MiddlewareRegistration.lane("bare", [BareLaneMarker()])
            + MiddlewareRegistration.lane("admin", [AdminLaneMarker()])
        let routes: [RouteRegistration] = [
            pingRoute,
            BareLaneController._flightRoute_bare_0 { _ in BareLaneController() },
            AdminController._flightRoute_admin_0 { _ in AdminController() },
            RouteLaneController._flightRoute_inherits_0 { _ in RouteLaneController() },
            RouteLaneController._flightRoute_replaced_1 { _ in RouteLaneController() },
            RouteLaneController._flightRoute_explicitlyPublic_2 { _ in RouteLaneController() },
        ]
        return try TestClient(routes: routes, middleware: middleware)
    }

    @Test("a route in a bare lane never runs the default stack")
    func bareLaneSkipsDefault() async throws {
        laneTrace.reset()
        #expect(try await client().get("/bare").status == .ok)
        #expect(laneTrace.entries == ["bare-lane"])
    }

    @Test("default routes run only the default lane")
    func defaultRoutesUnaffected() async throws {
        laneTrace.reset()
        _ = try await client().get("/ping")
        #expect(laneTrace.entries == ["default-lane"])
    }

    @Test("a route can concatenate the default lane with an extra one, in order")
    func defaultPlusExtra() async throws {
        laneTrace.reset()
        #expect(try await client().get("/admin").status == .ok)
        #expect(laneTrace.entries == ["default-lane", "admin-lane"])
    }

    @Test("a route with no lanes of its own inherits the controller's")
    func routeInheritsControllerLane() async throws {
        laneTrace.reset()
        #expect(try await client().get("/dash/inherits").status == .ok)
        #expect(laneTrace.entries == ["admin-lane"])
    }

    @Test("a route's own lanes replace the controller's, they do not add to them")
    func routeLanesReplaceControllerLanes() async throws {
        laneTrace.reset()
        #expect(try await client().get("/dash/replaced").status == .ok)
        #expect(laneTrace.entries == ["bare-lane"])
        #expect(!laneTrace.entries.contains("admin-lane"))
    }

    @Test(".public runs no middleware at all")
    func publicLaneRunsNothing() async throws {
        laneTrace.reset()
        #expect(try await client().get("/dash/public").status == .ok)
        #expect(laneTrace.entries.isEmpty)
    }

    @Test("a 404 runs the default lane, so logging still sees every miss")
    func notFoundRunsDefaultLane() async throws {
        laneTrace.reset()
        #expect(try await client().get("/no-such-route").status == .notFound)
        #expect(laneTrace.entries == ["default-lane"])
    }

    @Test("referencing an undeclared lane fails when dispatch is built, naming route and lane")
    func undeclaredLaneFails() throws {
        let ghost = RouteRegistration(
            method: "GET", path: "/ghost", source: "GhostModule",
            pipelines: ["nobody-declared-this"]
        ) { _ in .noContent }
        do {
            _ = try TestClient(routes: [ghost])
            Issue.record("expected dispatch build to refuse the undeclared lane")
        } catch let error as DispatchBuilder.UndeclaredLaneError {
            #expect(error.lane == "nobody-declared-this")
            #expect(error.route.contains("/ghost"))
        }
    }

    @Test("an empty lane declaration still declares the lane, and runs nothing")
    func emptyLaneIsDeclared() async throws {
        // A static-asset lane deliberately carrying no middleware. The marker
        // declares the lane; a route naming it validates and runs nothing.
        let asset = RouteRegistration(
            method: "GET", path: "/asset", source: "EmptyLaneModule", pipelines: ["assets"]
        ) { _ in .text("served") }
        let client = try TestClient(
            routes: [asset], middleware: MiddlewareRegistration.lane("assets", []))
        let response = await client.get("/asset")
        #expect(response.status == .ok)
        #expect(response.bodyText == "served")
    }
}
