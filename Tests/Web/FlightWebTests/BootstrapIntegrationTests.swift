import FlightCore
import FlightWeb
import FlightWebTesting
import Foundation
import HTTPTypes
import Testing

/// The full §8 path: `bootstrap` → module DAG → freeze →
/// `FlightWebModule<InMemoryTransport>`'s service builds dispatch and the
/// transport starts inside a real ServiceGroup — no socket involved (§5.4).
@Suite("FlightWebModule bootstrap (§5.3, §8)", .serialized)
struct BootstrapIntegrationTests {

    @Test func bootstrappedAppServesRequestsThroughInMemoryTransport() async throws {
        // The routes are values handed to the web module, which is what a
        // generated composition root does — `flightRoutes(graph)` produces
        // exactly these calls, and a controller is constructed per request.
        let users = UserService()
        let tracer = RequestTracer()
        let configuration = Configuration()
        let web = try FlightWebModule<InMemoryTransport>(
            configuration: configuration,
            routes: [
                UserController._flightRoute_getUser_0 {
                    _ in UserController(userService: users, tracer: tracer)
                },
                UserController._flightRoute_createUser_1 {
                    _ in UserController(userService: users, tracer: tracer)
                },
                UserController._flightRoute_deleteUser_2 {
                    _ in UserController(userService: users, tracer: tracer)
                },
            ])
        let app = Task {
            try await Flight.bootstrap(
                configuration: configuration,
                modules: [web] as [any FlightModule]
            )
        }
        defer { app.cancel() }

        try await InMemoryTransportHub.waitUntilRunning()

        let ok = try await InMemoryTransportHub.execute(Request(path: "/users/1"))
        #expect(ok.status == .ok)
        #expect(try ok.decodeJSON(User.self).name == "ada")

        let missing = try await InMemoryTransportHub.execute(Request(path: "/users/404"))
        #expect(missing.status == .notFound)

        app.cancel()
        _ = try? await app.value
        #expect(!InMemoryTransportHub.isRunning)
    }

    @Test func conflictingRoutesFailStartupLoudly() throws {
        // Two routes that collide. The web module builds its dispatch in
        // `init` now, so a route-table conflict fails *there* — at composition,
        // before assemble or the service's first breath — with the same
        // message it always gave.
        let configuration = Configuration()
        #expect(throws: (any Error).self) {
            _ = try FlightWebModule<InMemoryTransport>(
                configuration: configuration,
                routes: [
                    RouteRegistration(method: "GET", path: "/dup/:a", source: "A.first") { _ in
                        .noContent
                    },
                    RouteRegistration(method: "GET", path: "/dup/:b", source: "B.second") { _ in
                        .noContent
                    },
                ])
        }
        #expect(!InMemoryTransportHub.isRunning)
    }

    @Test func handRegisteredRoutesRideTheSamePipeline() async throws {
        // A route built by hand rather than by the @Controller macro is the
        // same RouteRegistration value and rides the same dispatch.
        let manual = RouteRegistration(
            method: "GET", path: "/manual/:x", source: "HandRoutedModule"
        ) { context in
            .text("manual \(context.pathParam("x") ?? "?")")
        }
        let client = try TestClient(routes: [manual])
        let response = await client.get("/manual/7")
        #expect(response.bodyText == "manual 7")
    }
}
