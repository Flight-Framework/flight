import FlightActuator
import FlightCore
import FlightWeb
import FlightWebTesting
import Foundation
import HTTPTypes
import Testing

/// The composed path: an `ActuatorModule` built the way the composition root
/// builds it — explicit environment, components handed over, health from the
/// shared registry — assembled and served through the full dispatch pipeline.
///
/// Serialized because the default `ActuatorModule.init()` reads `FLIGHT_ENV`
/// from the process environment, which these tests pin to a known value.
@Suite("Full bootstrap integration", .serialized)
struct IntegrationTests {

    init() {
        setenv("FLIGHT_ENV", "dev", 1)
    }

    @Test("compose → dispatch → dashboard, end to end")
    func endToEnd() async throws {
        // The composition root threads one health registry into the actuator;
        // here we report the assembled modules' health onto it directly.
        let health = ModuleHealthRegistry()
        health.reportHealth(.running, forModule: "ActuatorModule")
        health.reportHealth(.running, forModule: "SampleAppModule")

        let actuator = ActuatorModule(
            environment: .dev, exposure: .full,
            components: SampleAppModule.components, health: health, format: .json)

        let client = try TestClient(routes: actuator.routes)
        let response = await client.get("/actuator")
        #expect(response.status == .ok)
        let wire = try response.decodeJSON(SnapshotWire.self)

        #expect(wire.environment == "dev")
        let moduleNames = wire.modules.map(\.module)
        #expect(moduleNames.contains("ActuatorModule"))
        #expect(moduleNames.contains("SampleAppModule"))
        #expect(wire.modules.allSatisfy { $0.health == "running" })

        // Every component the *build* scanned for the app module. Six ordinary
        // ones plus SampleController — routes are reported as routes, never
        // folded in as components (the distinction §2.9 wanted).
        let sampleComponents = wire.components.filter { $0.sourceModule == "SampleAppModule" }
        #expect(sampleComponents.count == 7)
        // Actuator's own controller is listed like everything else.
        #expect(wire.components.contains { $0.type == "FlightActuator.ActuatorController" })
    }

    @Test("actuator registers no service — it is request-response only")
    func noLongRunningService() throws {
        let app = try Flight.assemble(
            configuration: Configuration(),
            modules: [ActuatorModule()]
        )
        #expect(app.services.isEmpty)
    }

    @Test("dashboard reports the gate's environment, not a re-read")
    func reportsGateEnvironment() async throws {
        // Module constructed with an explicit environment; the page must
        // report that same value even though FLIGHT_ENV says "dev".
        let actuator = ActuatorModule(
            environment: .staging, exposure: .full,
            components: SampleAppModule.components)
        let client = try TestClient(routes: actuator.routes)
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
        let health = ModuleHealthRegistry()
        let actuator = ActuatorModule(environment: .dev, health: health)
        health.reportHealth(.notStarted, forModule: "Slow")
        let client = try TestClient(routes: actuator.routes)

        #expect(await client.get("/actuator/health/live").status == .ok)
        #expect(await client.get("/actuator/health/ready").status == .serviceUnavailable)
        #expect(await client.get("/actuator/health").status == .serviceUnavailable)
    }

    @Test("a failed module is neither alive nor ready")
    func failedIsDownForBoth() async throws {
        struct Boom: Error {}
        let health = ModuleHealthRegistry()
        let actuator = ActuatorModule(environment: .dev, health: health)
        health.reportHealth(.failed(Boom()), forModule: "Broken")
        let client = try TestClient(routes: actuator.routes)

        #expect(await client.get("/actuator/health/live").status == .serviceUnavailable)
        #expect(await client.get("/actuator/health/ready").status == .serviceUnavailable)
    }

    @Test("a healthy app is up on every probe")
    func runningIsUpEverywhere() async throws {
        let health = ModuleHealthRegistry()
        let actuator = ActuatorModule(environment: .dev, health: health)
        health.reportHealth(.running, forModule: "Fine")
        let client = try TestClient(routes: actuator.routes)

        for path in ["/actuator/health", "/actuator/health/live", "/actuator/health/ready"] {
            let response = await client.get(path)
            #expect(response.status == .ok, "\(path) answered \(response.status)")
            #expect(response.bodyText.contains("\"status\":\"UP\""))
        }
    }
}
