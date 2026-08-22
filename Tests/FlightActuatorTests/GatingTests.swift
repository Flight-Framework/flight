import FlightActuator
import FlightCore
import FlightWeb
import FlightWebTesting
import HTTPTypes
import Testing

/// §4.1: in `.prod` the routes are simply not registered — nothing to probe
/// or misconfigure. Everywhere else the dashboard exists.
@Suite("Environment gating")
struct GatingTests {

    @Test("prod registers nothing at all")
    func prodRegistersNothing() throws {
        let container = try TestContainer.build { ActuatorModule(environment: .prod) }

        // Only the Configuration bean TestContainer itself registers —
        // no controller, no routes, no container self-registration.
        let registered = container.allRegistrations().map(\.typeName)
        #expect(!registered.contains("FlightActuator.ActuatorController"))
        #expect(!registered.contains("FlightWeb.RouteRegistration"))
        #expect(!registered.contains("FlightCore.Container"))
        #expect(registered == ["FlightConfig.Configuration"])
    }

    @Test("prod answers 404 for /actuator — the route does not exist")
    func prodServes404() async throws {
        let container = try TestContainer.build { ActuatorModule(environment: .prod) }
        let client = try TestClient(container: container)
        let response = await client.get("/actuator")
        #expect(response.status == .notFound)
    }

    @Test("every non-prod environment serves the dashboard",
          arguments: [FlightEnvironment.dev, .test, .staging])
    func nonProdServesDashboard(environment: FlightEnvironment) async throws {
        let container = try TestContainer.build { ActuatorModule(environment: environment) }
        let client = try TestClient(container: container)
        let response = await client.get("/actuator")
        #expect(response.status == .ok)
        #expect(response.bodyText.contains(environment.rawValue))
    }

    @Test("the route table entry is visible through Core introspection")
    func routeVisibleInIntrospection() throws {
        let container = try TestContainer.build { ActuatorModule(environment: .dev) }
        let routes = container.allRegistrations().filter {
            $0.typeName == "FlightWeb.RouteRegistration"
        }
        #expect(routes.count == 1)
        #expect(routes[0].qualifier?.hasPrefix("GET /actuator") == true)
        #expect(routes[0].sourceModule == "<direct>")  // TestContainer stamps nothing
    }

    @Test("an app that already registered Container itself still boots")
    func coexistsWithAppContainerRegistration() async throws {
        struct ContainerRegisteringModule: FlightModule {
            func configure(_ container: Container) throws {
                container.register(Container.self, scope: .singleton) { c in c }
            }
        }

        let container = try TestContainer.build {
            ContainerRegisteringModule()
            ActuatorModule(environment: .dev)
        }
        let containerBeans = container.allRegistrations().filter {
            $0.typeName == "FlightCore.Container" && $0.qualifier == nil
        }
        #expect(containerBeans.count == 1)

        let client = try TestClient(container: container)
        let response = await client.get("/actuator")
        #expect(response.status == .ok)
    }
}
