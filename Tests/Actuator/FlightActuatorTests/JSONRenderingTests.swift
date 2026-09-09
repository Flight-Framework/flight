import FlightActuator
import FlightCore
import FlightWeb
import FlightWebTesting
import Foundation
import HTTPTypes
import Testing

/// The Decodable mirror of Actuator's public JSON contract — decoded
/// with plain JSONDecoder to pin the wire shape, not just round-trip it.
struct SnapshotWire: Decodable {
    struct Module: Decodable {
        let module: String
        let health: String
        let error: String?
    }
    struct Component: Decodable {
        let type: String
        let scope: String
        let stereotype: String
        let qualifier: String?
        let sourceModule: String
    }
    let environment: String
    let modules: [Module]
    let components: [Component]
}

@Suite("JSON rendering")
struct JSONRenderingTests {

    /// The container plus the actuator's declared routes — a module's routes
    /// are values now, so a client that serves them has to be given them.
    private func jsonClient(environment: FlightEnvironment = .staging) throws -> TestClient {
        let actuator = ActuatorModule(
            environment: environment, exposure: .full,
            components: SampleAppModule.components)
        let container = try TestContainer.build(
            configuration: Configuration(values: ["actuator.format": "json"])
        ) {
            actuator
            SampleAppModule()
        }
        return try TestClient(container: container, routes: actuator.routes)
    }

    @Test("dashboard serves application/json when configured")
    func servesJSONContentType() async throws {
        let client = try jsonClient()
        let response = await client.get("/actuator")
        #expect(response.status == .ok)
        #expect(response.headers[.contentType] == "application/json; charset=utf-8")
    }

    @Test("the wire shape carries environment, modules, and components")
    func wireShape() async throws {
        let client = try jsonClient(environment: .staging)
        let response = await client.get("/actuator")
        let wire = try response.decodeJSON(SnapshotWire.self)

        #expect(wire.environment == "staging")

        let service = try #require(wire.components.first {
            $0.type == "FlightActuatorTests.SampleService"
        })
        #expect(service.scope == "singleton")
        #expect(service.stereotype == "service")
        #expect(service.qualifier == nil)

        let qualified = wire.components.filter { $0.type == "FlightActuatorTests.SampleQualified" }
        #expect(qualified.compactMap(\.qualifier).sorted() == ["primary", "secondary"])

        // Actuator's own machinery is visible through the same introspection
        // as everything else — no side channel, no special casing.
        #expect(wire.components.contains { $0.type == "FlightActuator.ActuatorController" })
        // Routes are not asserted here: they are values a module declares, and
        // they reach the container through `FlightWebModule`, which this
        // container does not include. `GatingTests` covers that path.
    }

    @Test("a failed module encodes health 'failed' with its error")
    func failedModuleOnTheWire() async throws {
        let app = try Flight.assemble(
            configuration: Configuration(),
            modules: [FailingServiceModule.self]
        )
        let failing = try #require(app.services.first)
        _ = try? await failing.service.run()

        let snapshot = ActuatorSnapshot(container: app.container, environment: .test)
        let data = try JSONEncoder().encode(snapshot)
        let wire = try JSONDecoder().decode(SnapshotWire.self, from: data)

        let module = try #require(wire.modules.first { $0.module == "FailingServiceModule" })
        #expect(module.health == "failed")
        #expect(module.error?.contains("flux capacitor") == true)
    }

    @Test("a healthy module encodes with a null error")
    func healthyModuleOnTheWire() throws {
        let app = try Flight.assemble(configuration: Configuration(), modules: [FailingServiceModule.self])
        let snapshot = ActuatorSnapshot(container: app.container, environment: .dev)
        let data = try JSONEncoder().encode(snapshot)
        let wire = try JSONDecoder().decode(SnapshotWire.self, from: data)

        #expect(wire.environment == "dev")
        let module = try #require(wire.modules.first)
        #expect(module.health == "running")
        #expect(module.error == nil)
    }

    @Test("JSON output is deterministic across requests")
    func deterministicOutput() async throws {
        let client = try jsonClient()
        let first = await client.get("/actuator")
        let second = await client.get("/actuator")
        #expect(first.bodyData == second.bodyData)
    }
}
