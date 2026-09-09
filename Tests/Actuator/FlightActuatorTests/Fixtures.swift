import FlightActuator
import FlightCore
import FlightWeb
import ServiceLifecycle

// Shared test fixtures. All go through public Flight contracts only —
// Actuator is a consumer of the stack, and so are its tests.

/// A module registering one component of each stereotype the dashboard needs
/// to distinguish, plus a qualified duplicate-type pair.
struct SampleAppModule: FlightModule {
    /// What the build would have scanned for this module, in the shape the
    /// generated `flightComponentDescriptors()` produces. Written out here
    /// because these fixtures register by hand and no plugin runs over them —
    /// the dashboard lists what the *build* found, not what the container
    /// happens to hold.
    static let components: [ComponentDescriptor] = [
        ComponentDescriptor(
            typeName: "FlightActuatorTests.SampleService", scope: .singleton,
            sourceModule: "SampleAppModule", qualifier: nil, stereotype: .service),
        ComponentDescriptor(
            typeName: "FlightActuatorTests.SampleRepository", scope: .singleton,
            sourceModule: "SampleAppModule", qualifier: nil, stereotype: .repository),
        ComponentDescriptor(
            typeName: "FlightActuatorTests.SampleQualified", scope: .singleton,
            sourceModule: "SampleAppModule", qualifier: "primary", stereotype: .component),
        ComponentDescriptor(
            typeName: "FlightActuatorTests.SampleQualified", scope: .singleton,
            sourceModule: "SampleAppModule", qualifier: "secondary", stereotype: .component),
        ComponentDescriptor(
            typeName: "FlightActuatorTests.SampleMiddleware", scope: .singleton,
            sourceModule: "SampleAppModule", qualifier: nil, stereotype: .middleware),
        ComponentDescriptor(
            typeName: "FlightActuatorTests.SampleSettings", scope: .singleton,
            sourceModule: "SampleAppModule", qualifier: nil, stereotype: .settings),
        ComponentDescriptor(
            typeName: "FlightActuatorTests.SampleController", scope: .singleton,
            sourceModule: "SampleAppModule", qualifier: nil, stereotype: .controller),
    ]

    func configure(_ container: Container) throws {
        container.register(SampleService.self, scope: .singleton, stereotype: .service) { _ in
            SampleService()
        }
        container.register(SampleRepository.self, scope: .singleton, stereotype: .repository) { _ in
            SampleRepository()
        }
        container.register(SampleQualified.self, qualifier: "primary", scope: .singleton) { _ in
            SampleQualified()
        }
        container.register(SampleQualified.self, qualifier: "secondary", scope: .singleton) { _ in
            SampleQualified()
        }
        container.register(SampleMiddleware.self, scope: .singleton, stereotype: .middleware) { _ in
            SampleMiddleware()
        }
        container.register(SampleSettings.self, scope: .singleton, stereotype: .settings) { _ in
            SampleSettings()
        }
        // A real `@Controller`, expanded by the macro, rather than a
        // hand-registered stand-in passing `stereotype:` itself. Which
        // stereotype a controller lands under is the macro's decision, and
        // every other entry here being hand-registered is why it went
        // unnoticed that the macro was not making it.
        try SampleController._flightRegister(container)
    }
}

struct SampleService: Sendable {}
struct SampleRepository: Sendable {}
struct SampleQualified: Sendable {}
struct SampleMiddleware: Sendable {}
struct SampleSettings: Sendable {}

@Controller("/sample")
struct SampleController {
    @GetRoute("/ping")
    func ping(_ context: RequestContext) -> String { "pong" }
}

/// A module registering a component whose qualifier is an XSS probe — the SSR
/// escaping tests feed the renderer through this.
struct HostileQualifierModule: FlightModule {
    static let hostileQualifier = #"<script>alert("pwned")</script>"#

    static let components: [ComponentDescriptor] = [
        ComponentDescriptor(
            typeName: "FlightActuatorTests.SampleQualified", scope: .singleton,
            sourceModule: "HostileQualifierModule", qualifier: hostileQualifier,
            stereotype: .component)
    ]

    func configure(_ container: Container) throws {
        container.register(
            SampleQualified.self,
            qualifier: Self.hostileQualifier,
            scope: .singleton
        ) { _ in SampleQualified() }
    }
}

/// A module whose service fails during the run phase — the only way module
/// health legitimately reaches `.failed` on a live container (Flight Core
///: configure failures abort bootstrap entirely).
struct FailingServiceModule: FlightModule {
    struct Boom: Error, CustomStringConvertible {
        var description: String { "boom: the flux capacitor de-fluxed" }
    }

    struct FailingService: Service {
        func run() async throws {
            throw Boom()
        }
    }

    func configure(_ container: Container) throws {}

    var service: (any Service)? { FailingService() }
}
