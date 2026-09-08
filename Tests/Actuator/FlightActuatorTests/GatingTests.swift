import FlightActuator
import FlightCore
import FlightWeb
import FlightWebTesting
import HTTPTypes
import Testing

/// Which routes exist, and in which environments.
///
/// The gate used to be `environment != .prod`, which fails open twice over:
/// an unset `FLIGHT_ENV` resolves to `dev`, and any spelling the code does
/// not recognize — `production`, `PROD`, `prd` — is also not `.prod`. Both
/// published the full topology endpoint, unauthenticated, on a deployment
/// whose operator believed otherwise. It is an allowlist now: development
/// environments get the dashboard, everything else gets health only.
@Suite("Environment gating")
struct GatingTests {

    @Test("prod answers 404 for the dashboard — the route does not exist")
    func prodServes404() async throws {
        let actuator = ActuatorModule(environment: .prod)
        let container = try TestContainer.build { actuator }
        let client = try TestClient(container: container, routes: actuator.routes)
        #expect(await client.get("/actuator").status == .notFound)
    }

    @Test("prod still serves health — a probe endpoint is not a disclosure")
    func prodServesHealth() async throws {
        // The old all-or-nothing gate is why production had no health check
        // at all: blocking the dashboard blocked the probe with it.
        let actuator = ActuatorModule(environment: .prod)
        let container = try TestContainer.build { actuator }
        let client = try TestClient(container: container, routes: actuator.routes)
        let response = await client.get("/actuator/health")
        #expect(response.status == .ok)
        #expect(response.bodyText.contains("\"status\":\"UP\""))
    }

    @Test("development environments serve the dashboard",
          arguments: [FlightEnvironment.dev, .test, FlightEnvironment("local")])
    func developmentServesDashboard(environment: FlightEnvironment) async throws {
        let actuator = ActuatorModule(environment: environment)
        let container = try TestContainer.build { actuator }
        let client = try TestClient(container: container, routes: actuator.routes)
        let response = await client.get("/actuator")
        #expect(response.status == .ok)
        #expect(response.bodyText.contains(environment.rawValue))
    }

    @Test("anything not recognized as development gets health only",
          arguments: [
            FlightEnvironment.staging, .prod,
            FlightEnvironment("production"), FlightEnvironment("PROD"),
            FlightEnvironment("prd"), FlightEnvironment("live"),
          ])
    func unrecognizedEnvironmentsAreClosed(environment: FlightEnvironment) async throws {
        // Each of these was `!= .prod` and therefore published the dashboard.
        let actuator = ActuatorModule(environment: environment)
        let container = try TestContainer.build { actuator }
        let client = try TestClient(container: container, routes: actuator.routes)
        #expect(await client.get("/actuator").status == .notFound)
        #expect(await client.get("/actuator/health").status == .ok)
    }

    @Test("an explicit exposure opts a non-development environment in")
    func explicitExposureOptsIn() async throws {
        let actuator = ActuatorModule(environment: .staging, exposure: .full)
        let container = try TestContainer.build { actuator }
        let client = try TestClient(container: container, routes: actuator.routes)
        #expect(await client.get("/actuator").status == .ok)
    }

    @Test("disabled registers nothing at all")
    func disabledRegistersNothing() throws {
        let actuator = ActuatorModule(environment: .dev, exposure: .disabled)
        let container = try TestContainer.build { actuator }
        let registered = container.allRegistrations().map(\.typeName)
        #expect(!registered.contains("FlightActuator.ActuatorController"))
        #expect(!registered.contains("FlightWeb.RouteRegistration"))
        #expect(registered == ["FlightConfig.Configuration"])
    }

    @Test("an unrecognized FLIGHT_ACTUATOR_EXPOSURE stops startup")
    func unknownExposureRejected() {
        #expect(throws: ActuatorConfigurationError.self) {
            _ = try ActuatorExposure.resolve(
                environment: .prod,
                processEnvironment: ["FLIGHT_ACTUATOR_EXPOSURE": "everything"])
        }
    }

    @Test("the exposure default is closed for anything unrecognized")
    func defaultsAreClosed() throws {
        #expect(try ActuatorExposure.resolve(environment: .dev, processEnvironment: [:]) == .full)
        #expect(try ActuatorExposure.resolve(environment: .test, processEnvironment: [:]) == .full)
        for name in ["staging", "prod", "production", "PROD", "prd", "qa", "anything"] {
            #expect(
                try ActuatorExposure.resolve(
                    environment: FlightEnvironment(name), processEnvironment: [:]) == .healthOnly,
                "\(name) must not publish the dashboard by default")
        }
    }

    @Test("a deployment that declared nothing does not get the dashboard")
    func undeclaredEnvironmentGetsHealthOnly() async throws {
        // The allowlist closed the misspelled-name half of the old fail-open
        // gate and left the other half byte-for-byte intact: an unset
        // FLIGHT_ENV resolves to `dev`, `dev` is on the allowlist, so a
        // production deployment that never set the variable served the whole
        // unauthenticated topology dashboard — while Docs/actuator.md claimed
        // getting the environment wrong "costs you a dashboard instead of
        // leaking one".
        let actuator = ActuatorModule(processEnvironment: [:])
        let container = try TestContainer.build { actuator }
        let client = try TestClient(container: container, routes: actuator.routes)
        #expect(await client.get("/actuator").status == .notFound)
        #expect(await client.get("/actuator/health").status == .ok)
    }

    @Test("declaring dev explicitly still gets the dashboard")
    func declaredDevGetsDashboard() async throws {
        let actuator = ActuatorModule(processEnvironment: ["FLIGHT_ENV": "dev"])
        let container = try TestContainer.build { actuator }
        let client = try TestClient(container: container, routes: actuator.routes)
        #expect(await client.get("/actuator").status == .ok)
    }

    @Test("an undeclared environment can still opt in explicitly")
    func undeclaredCanOptIn() throws {
        #expect(
            try ActuatorExposure.resolve(
                environment: .dev, isEnvironmentDeclared: false,
                processEnvironment: ["FLIGHT_ACTUATOR_EXPOSURE": "full"]) == .full)
    }

    @Test("the module declares its four routes as values")
    func routeVisibleInIntrospection() throws {
        // Declared as values now, so this is where the truth is — they used to
        // be `registerRoute` calls and this asserted on the container.
        // `FlightWebModule` is what puts them back in a container, for the
        // dashboard to list; `WebModuleTests` covers that.
        let actuator = ActuatorModule(environment: .dev)
        // The dashboard, plus the three health probes: the aggregate, and the
        // liveness/readiness pair that answer the two different questions an
        // orchestrator asks.
        #expect(actuator.routes.count == 4)
        #expect(
            Set(actuator.routes.map { "\($0.method.rawValue) \($0.path) @\($0.source)" }) == [
                "GET /actuator @FlightActuator",
                "GET /actuator/health @FlightActuator",
                "GET /actuator/health/live @FlightActuator",
                "GET /actuator/health/ready @FlightActuator",
            ])
    }

    @Test("an app that already registered Container itself still boots")
    func coexistsWithAppContainerRegistration() async throws {
        struct ContainerRegisteringModule: FlightModule {
            func configure(_ container: Container) throws {
                container.register(Container.self, scope: .singleton) { c in c }
            }
        }

        let actuator = ActuatorModule(environment: .dev)
        let container = try TestContainer.build {
            ContainerRegisteringModule()
            actuator
        }
        let containerBeans = container.allRegistrations().filter {
            $0.typeName == "FlightCore.Container" && $0.qualifier == nil
        }
        #expect(containerBeans.count == 1)

        let client = try TestClient(container: container, routes: actuator.routes)
        let response = await client.get("/actuator")
        #expect(response.status == .ok)
    }
}
