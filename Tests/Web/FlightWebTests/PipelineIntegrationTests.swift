// End-to-end: `@Middleware` + `container.pipeline { }`, driven through a
// real Dispatch via TestClient — not just the macro's generated text
// (MiddlewareMacroFixtureTests) or a hand-composed chain (MiddlewareTests).

import FlightCore
import FlightWeb
import FlightWebTesting
import Foundation
import HTTPTypes
import Synchronization
import Testing

// MARK: - Fixtures

/// A plain reference type so several independently-resolved `@Middleware`
/// instances can share one trace.
final class TraceBox: Sendable {
    private let storage = Mutex<[String]>([])
    func append(_ name: String) { storage.withLock { $0.append(name) } }
    func reset() { storage.withLock { $0.removeAll() } }
    var entries: [String] { storage.withLock { $0 } }
}

private let sharedTrace = TraceBox()

@Middleware
struct NeverListed: Sendable {
    func handle(_ context: RequestContext, next: Next) async throws -> Response {
        sharedTrace.append("never-listed")
        return try await next(context)
    }
}

struct PingController {
    static func register(_ container: Container) throws {
        container.registerRoute(.get, "/ping", source: "PingController") { _ in .text("pong") }
    }
}

// MARK: - A single `pipeline { }` call preserves declared order

@Middleware
struct OrderA: Sendable {
    func handle(_ context: RequestContext, next: Next) async throws -> Response {
        sharedTrace.append("A")
        return try await next(context)
    }
}

@Middleware
struct OrderB: Sendable {
    func handle(_ context: RequestContext, next: Next) async throws -> Response {
        sharedTrace.append("B")
        return try await next(context)
    }
}

@Middleware
struct OrderC: Sendable {
    func handle(_ context: RequestContext, next: Next) async throws -> Response {
        sharedTrace.append("C")
        return try await next(context)
    }
}

private struct OrderModule: FlightModule {
    func configure(_ container: Container) throws {
        try OrderA._flightRegister(container)
        try OrderB._flightRegister(container)
        try OrderC._flightRegister(container)
        try PingController.register(container)
        container.pipeline {
            OrderA.self
            OrderB.self
            OrderC.self
        }
    }
}

// MARK: - Cross-module composition: two `pipeline { }` calls concatenate,
// module order first — the exact bug this design caught before shipping
// (see RouteRegistration.swift's `pipeline(_:)` doc comment).

@Middleware
struct FrameworkLayerOne: Sendable {
    func handle(_ context: RequestContext, next: Next) async throws -> Response {
        sharedTrace.append("framework-1")
        return try await next(context)
    }
}

@Middleware
struct FrameworkLayerTwo: Sendable {
    func handle(_ context: RequestContext, next: Next) async throws -> Response {
        sharedTrace.append("framework-2")
        return try await next(context)
    }
}

@Middleware
struct AppLayerOne: Sendable {
    func handle(_ context: RequestContext, next: Next) async throws -> Response {
        sharedTrace.append("app-1")
        return try await next(context)
    }
}

/// Stands in for a framework module (Flight Security, say) that installs its
/// own middleware from its own `configure(_:)`, independently of whatever
/// the application declares. Two entries, deliberately — this is what
/// exposes the per-call-index bug this design caught before shipping: an
/// app with a *single* pipeline { } entry would tie with this call's first
/// entry on a per-call index (both "position 0"), and a naive tiebreak would
/// then let the app's one entry sort ahead of this module's *second* entry
/// even though the whole framework call ran first. Concatenating by
/// registration sequence instead — what `pipeline(_:)` actually does — is
/// exactly what keeps that from happening.
private struct FrameworkModule: FlightModule {
    func configure(_ container: Container) throws {
        try FrameworkLayerOne._flightRegister(container)
        try FrameworkLayerTwo._flightRegister(container)
        container.pipeline {
            FrameworkLayerOne.self
            FrameworkLayerTwo.self
        }
    }
}

private struct AppModule: FlightModule {
    static var dependencies: [any FlightModule.Type] { [FrameworkModule.self] }

    func configure(_ container: Container) throws {
        try AppLayerOne._flightRegister(container)
        try PingController.register(container)
        container.pipeline {
            AppLayerOne.self
        }
    }
}

// MARK: - Interop with the deprecated closure API

@Middleware
struct NewStyleFirst: Sendable {
    func handle(_ context: RequestContext, next: Next) async throws -> Response {
        sharedTrace.append("new")
        return try await next(context)
    }
}

private struct MixedModule: FlightModule {
    func configure(_ container: Container) throws {
        try NewStyleFirst._flightRegister(container)
        try PingController.register(container)
        // Deliberately registered "first" with a very negative order, and
        // the pipeline{} call written after it in source — neither should
        // matter. pipeline{} entries always run outermost regardless.
        container.registerMiddleware("legacy", order: -1_000) { context, next in
            var mutableContext = context
            sharedTrace.append("legacy")
            return await next(&mutableContext)
        }
        container.pipeline {
            NewStyleFirst.self
        }
    }
}

// MARK: - Tests

@Suite("container.pipeline { } — ordering and composition", .serialized)
struct PipelineIntegrationTests {

    @Test("declared order within one pipeline { } call is preserved")
    func singlePipelineCallOrder() async throws {
        sharedTrace.reset()
        let client = try TestClient(container: TestContainer.build { OrderModule() })
        let response = await client.get("/ping")
        #expect(response.status == .ok)
        #expect(sharedTrace.entries == ["A", "B", "C"])
    }

    @Test("two pipeline { } calls from different modules concatenate in module order")
    func crossModuleComposition() async throws {
        sharedTrace.reset()
        // AppModule depends on FrameworkModule, so FrameworkModule.configure
        // runs first — both of its pipeline { } entries must run outermost,
        // ahead of AppModule's, in the order FrameworkModule itself declared
        // them.
        let client = try TestClient(container: TestContainer.build { AppModule() })
        let response = await client.get("/ping")
        #expect(response.status == .ok)
        #expect(sharedTrace.entries == ["framework-1", "framework-2", "app-1"])
    }

    @Test("a pipeline { } entry always runs ahead of a deprecated registerMiddleware closure")
    func newGenerationRunsFirst() async throws {
        sharedTrace.reset()
        // The legacy closure declares order: -1_000 — the most aggressive
        // "run first" a pre-@Middleware app could write. It must still lose
        // to the pipeline{} entry, which carries no explicit order at all.
        let client = try TestClient(container: TestContainer.build { MixedModule() })
        let response = await client.get("/ping")
        #expect(response.status == .ok)
        #expect(sharedTrace.entries == ["new", "legacy"])
    }

    @Test("a @Middleware type in no pipeline { } is resolvable but never runs")
    func unlistedMiddlewareIsInertNotBroken() async throws {
        sharedTrace.reset()
        struct QuietModule: FlightModule {
            func configure(_ container: Container) throws {
                try NeverListed._flightRegister(container)
                try PingController.register(container)
                // No pipeline { } call naming NeverListed at all.
            }
        }
        let container = try TestContainer.build { QuietModule() }
        // Resolvable — an ordinary, independently testable component.
        _ = try container.resolve(NeverListed.self)

        let client = try TestClient(container: container)
        let response = await client.get("/ping")
        #expect(response.status == .ok)
        #expect(sharedTrace.entries.isEmpty, "a type absent from every pipeline { } must not run")
    }
}

// MARK: - Lanes

/// Its own box: `.serialized` serializes tests within one suite, but the two
/// pipeline suites run concurrently with each other — sharing one trace
/// across them interleaves entries exactly often enough to flake.
private let laneTrace = TraceBox()

@Middleware
struct DefaultLaneMarker: Sendable {
    func handle(_ context: RequestContext, next: Next) async throws -> Response {
        laneTrace.append("default-lane")
        return try await next(context)
    }
}

@Middleware
struct BareLaneMarker: Sendable {
    func handle(_ context: RequestContext, next: Next) async throws -> Response {
        laneTrace.append("bare-lane")
        return try await next(context)
    }
}

@Middleware
struct AdminLaneMarker: Sendable {
    func handle(_ context: RequestContext, next: Next) async throws -> Response {
        laneTrace.append("admin-lane")
        return try await next(context)
    }
}

/// A controller routed through a bare lane — the static-asset shape: the
/// default stack (transactions, auth, logging) must never run for it.
@Controller(pipelines: ["bare"])
struct BareLaneController {
    @GetMapping("/bare")
    func bare(_ context: RequestContext) -> String { "bare" }
}

/// The default stack plus an extra lane, concatenated in that order.
@Controller(pipelines: [MiddlewareRegistration.defaultLane, "admin"])
struct AdminController {
    @GetMapping("/admin")
    func admin(_ context: RequestContext) -> String { "admin" }
}

private struct LanesModule: FlightModule {
    func configure(_ container: Container) throws {
        try DefaultLaneMarker._flightRegister(container)
        try BareLaneMarker._flightRegister(container)
        try AdminLaneMarker._flightRegister(container)
        try BareLaneController._flightRegister(container)
        try AdminController._flightRegister(container)
        try PingController.register(container)
        container.pipeline {
            DefaultLaneMarker.self
        }
        container.pipeline("bare") {
            BareLaneMarker.self
        }
        container.pipeline("admin") {
            AdminLaneMarker.self
        }
    }
}

@Suite("pipeline lanes", .serialized)
struct PipelineLaneTests {

    @Test("a route in a bare lane never runs the default stack")
    func bareLaneSkipsDefault() async throws {
        // THE motivating case: a static-asset route must not lease a
        // database connection or run auth just because the app's default
        // pipeline does. If this fails, lanes are decoration.
        laneTrace.reset()
        let client = try TestClient(container: TestContainer.build { LanesModule() })
        let response = await client.get("/bare")
        #expect(response.status == .ok)
        #expect(laneTrace.entries == ["bare-lane"])
        #expect(!laneTrace.entries.contains("default-lane"))
    }

    @Test("default routes run only the default lane")
    func defaultRoutesUnaffected() async throws {
        laneTrace.reset()
        let client = try TestClient(container: TestContainer.build { LanesModule() })
        _ = await client.get("/ping")
        #expect(laneTrace.entries == ["default-lane"])
    }

    @Test("a route can concatenate the default lane with an extra one, in order")
    func defaultPlusExtra() async throws {
        laneTrace.reset()
        let client = try TestClient(container: TestContainer.build { LanesModule() })
        let response = await client.get("/admin")
        #expect(response.status == .ok)
        #expect(laneTrace.entries == ["default-lane", "admin-lane"])
    }

    @Test("a 404 runs the default lane, so logging still sees every miss")
    func notFoundRunsDefaultLane() async throws {
        laneTrace.reset()
        let client = try TestClient(container: TestContainer.build { LanesModule() })
        let response = await client.get("/no-such-route")
        #expect(response.status == .notFound)
        #expect(laneTrace.entries == ["default-lane"])
    }

    @Test("referencing an undeclared lane fails at build, naming route and lane")
    func undeclaredLaneFailsAtBootstrap() throws {
        struct GhostModule: FlightModule {
            func configure(_ container: Container) throws {
                container.registerRoute(
                    .get, "/ghost", source: "GhostModule", pipelines: ["nobody-declared-this"]
                ) { _ in .noContent }
            }
        }
        let container = try TestContainer.build { GhostModule() }
        do {
            _ = try TestClient(container: container)
            Issue.record("expected dispatch build to refuse the undeclared lane")
        } catch let error as DispatchBuilder.UndeclaredLaneError {
            #expect(error.lane == "nobody-declared-this")
            #expect(error.route.contains("/ghost"))
        }
    }
}
