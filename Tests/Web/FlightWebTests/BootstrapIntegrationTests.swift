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
        let app = Task {
            try await Flight.bootstrap(
                configuration: Configuration(),
                modules: [FlightWebModule<InMemoryTransport>.self, UserModule.self]
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

    @Test func conflictingRoutesFailStartupLoudly() async throws {
        struct ConflictModule: FlightModule {
            func configure(_ container: Container) throws {
                container.registerRoute(.get, "/dup/:a", source: "A.first") { _ in .noContent }
                container.registerRoute(.get, "/dup/:b", source: "B.second") { _ in .noContent }
            }
        }
        let app = Task {
            try await Flight.bootstrap(
                configuration: Configuration(),
                modules: [FlightWebModule<InMemoryTransport>.self, ConflictModule.self]
            )
        }
        // The web service throws during dispatch assembly; the ServiceGroup
        // fails the app — bootstrap rethrows rather than serving.
        await #expect(throws: Error.self) {
            try await app.value
        }
        #expect(!InMemoryTransportHub.isRunning)
    }

    @Test func handRegisteredRoutesRideTheSamePipeline() async throws {
        struct HandRoutedModule: FlightModule {
            func configure(_ container: Container) throws {
                container.registerRoute(.get, "/manual/:x", source: "HandRoutedModule") { context in
                    .text("manual \(context.pathParam("x") ?? "?")")
                }
            }
        }
        let client = try TestClient(container: TestContainer.build { HandRoutedModule() })
        let response = await client.get("/manual/7")
        #expect(response.bodyText == "manual 7")
    }
}
