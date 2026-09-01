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

    private func jsonContainer(environment: FlightEnvironment = .staging) throws -> Container {
        try TestContainer.build(
            configuration: Configuration(values: ["actuator.format": "json"])
        ) {
            ActuatorModule(environment: environment, exposure: .full)
            SampleAppModule()
        }
    }

    @Test("dashboard serves application/json when configured")
    func servesJSONContentType() async throws {
        let client = try TestClient(container: jsonContainer())
        let response = await client.get("/actuator")
        #expect(response.status == .ok)
        #expect(response.headers[.contentType] == "application/json; charset=utf-8")
    }

    @Test("the wire shape carries environment, modules, and components")
    func wireShape() async throws {
        let client = try TestClient(container: jsonContainer(environment: .staging))
        let response = await client.get("/actuator")
        let wire = try response.decodeJSON(SnapshotWire.self)

        #expect(wire.environment == "staging")

        let service = try #require(wire.components.first {
            $0.type == "FlightActuatorTests.SampleService"
        })
        #expect(service.scope == "singleton")
        #expect(service.stereotype == "service")
        #expect(service.qualifier == nil)

        let transient = try #require(wire.components.first {
            $0.type == "FlightActuatorTests.SampleTransient"
        })
        #expect(transient.scope == "transient")

        let qualified = wire.components.filter { $0.type == "FlightActuatorTests.SampleQualified" }
        #expect(qualified.compactMap(\.qualifier).sorted() == ["primary", "secondary"])

        // Actuator's own machinery is visible through the same introspection
        // as everything else — no side channel, no special casing.
        #expect(wire.components.contains { $0.type == "FlightActuator.ActuatorController" })
        #expect(wire.components.contains { $0.type == "FlightWeb.RouteRegistration" })
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
        let client = try TestClient(container: jsonContainer())
        let first = await client.get("/actuator")
        let second = await client.get("/actuator")
        #expect(first.bodyData == second.bodyData)
    }
}
