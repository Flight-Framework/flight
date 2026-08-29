import FlightActuator
import FlightCore
import FlightWeb
import FlightWebTesting
import Foundation
import HTTPTypes
import Testing

/// The real bootstrap path (Flight Core): `assemble` with
/// `ActuatorModule.self` as a module *type* — instantiated via `init()`,
/// health-tracked, source-module-stamped — then served through the full
/// dispatch pipeline.
///
/// Serialized because the default `ActuatorModule.init()` reads `FLIGHT_ENV`
/// from the process environment, which these tests pin to a known value.
@Suite("Full bootstrap integration", .serialized)
struct IntegrationTests {

    init() {
        setenv("FLIGHT_ENV", "dev", 1)
    }

    @Test("assemble → dispatch → dashboard, end to end")
    func endToEnd() async throws {
        let app = try Flight.assemble(
            configuration: Configuration(values: ["actuator.format": "json"]),
            modules: [ActuatorModule.self, SampleAppModule.self]
        )

        // Bootstrap stamped Actuator's registrations with the module name.
        let controller = try #require(app.container.allRegistrations().first {
            $0.typeName == "FlightActuator.ActuatorController"
        })
        #expect(controller.sourceModule == "ActuatorModule")

        // Both modules configured → running (Flight Core).
        let client = try TestClient(container: app.container)
        let response = await client.get("/actuator")
        #expect(response.status == .ok)
        let wire = try response.decodeJSON(SnapshotWire.self)

        #expect(wire.environment == FlightEnvironment.current().rawValue)
        let moduleNames = wire.modules.map(\.module)
        #expect(moduleNames.contains("ActuatorModule"))
        #expect(moduleNames.contains("SampleAppModule"))
        #expect(wire.modules.allSatisfy { $0.health == "running" })

        // Every bean the sample module registered is attributed to it.
        let sampleBeans = wire.beans.filter { $0.sourceModule == "SampleAppModule" }
        #expect(sampleBeans.count == 7)
    }

    @Test("actuator registers no service — it is request-response only")
    func noLongRunningService() throws {
        let app = try Flight.assemble(
            configuration: Configuration(),
            modules: [ActuatorModule.self]
        )
        #expect(app.services.isEmpty)
    }

    @Test("dashboard reports the gate's environment, not a re-read")
    func reportsGateEnvironment() async throws {
        // Module constructed with an explicit environment; the page must
        // report that same value even though FLIGHT_ENV says "dev".
        let container = try TestContainer.build { ActuatorModule(environment: .staging, exposure: .full) }
        let client = try TestClient(container: container)
        let body = await client.get("/actuator").bodyText
        #expect(body.contains("Environment: <strong>staging</strong>"))
    }
}

/// Liveness and readiness are different questions, and one endpoint answering
/// both got one of them wrong whichever way it was wired.
@Suite("Liveness and readiness")
struct ProbeTests {

    @Test("a module still starting is not ready, but is alive")
    func notStartedSplitsTheProbes() async throws {
        // The distinction that matters operationally: `notStarted` counted
        // toward DOWN on the single endpoint, so used as a liveness probe it
        // restart-looped a slow-starting pod into the same slow start,
        // forever.
        let container = try TestContainer.build { ActuatorModule(environment: .dev) }
        container.reportHealth(.notStarted, forModule: "Slow")
        let client = try TestClient(container: container)

        #expect(await client.get("/actuator/health/live").status == .ok)
        #expect(await client.get("/actuator/health/ready").status == .serviceUnavailable)
        #expect(await client.get("/actuator/health").status == .serviceUnavailable)
    }

    @Test("a failed module is neither alive nor ready")
    func failedIsDownForBoth() async throws {
        struct Boom: Error {}
        let container = try TestContainer.build { ActuatorModule(environment: .dev) }
        container.reportHealth(.failed(Boom()), forModule: "Broken")
        let client = try TestClient(container: container)

        #expect(await client.get("/actuator/health/live").status == .serviceUnavailable)
        #expect(await client.get("/actuator/health/ready").status == .serviceUnavailable)
    }

    @Test("a healthy app is up on every probe")
    func runningIsUpEverywhere() async throws {
        let container = try TestContainer.build { ActuatorModule(environment: .dev) }
        container.reportHealth(.running, forModule: "Fine")
        let client = try TestClient(container: container)

        for path in ["/actuator/health", "/actuator/health/live", "/actuator/health/ready"] {
            let response = await client.get(path)
            #expect(response.status == .ok, "\(path) answered \(response.status)")
            #expect(response.bodyText.contains("\"status\":\"UP\""))
        }
    }
}
