import FlightActuator
import FlightCore
import FlightWeb
import ServiceLifecycle

// Shared test fixtures. All go through public Flight contracts only —
// Actuator is a consumer of the stack, and so are its tests.

/// The components one sample app would contribute — one of each stereotype
/// the dashboard needs to distinguish, plus a qualified duplicate-type pair.
///
/// This is the shape the generated `flightComponentDescriptors()` produces
/// and the composition root hands `ActuatorModule(components:)`. Written out
/// here because no plugin runs over these fixtures — the dashboard lists what
/// the *build* found, not what any container happened to hold.
enum SampleAppModule {
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
}

struct SampleService: Sendable {}
struct SampleRepository: Sendable {}
struct SampleQualified: Sendable {}
struct SampleMiddleware: Sendable {}
struct SampleSettings: Sendable {}

/// A real `@Controller`, expanded by the macro, so the fixture's controller
/// descriptor stands for an actual controller type rather than a string.
@Controller("/sample")
struct SampleController {
    @GetRoute("/ping")
    func ping(_ context: RequestContext) -> String { "pong" }
}

/// The components for a module whose qualifier is an XSS probe — the SSR
/// escaping tests feed the renderer through these.
enum HostileQualifierModule {
    static let hostileQualifier = #"<script>alert("pwned")</script>"#

    static let components: [ComponentDescriptor] = [
        ComponentDescriptor(
            typeName: "FlightActuatorTests.SampleQualified", scope: .singleton,
            sourceModule: "HostileQualifierModule", qualifier: hostileQualifier,
            stereotype: .component)
    ]
}

/// A module whose service fails during the run phase — the only way module
/// health legitimately reaches `.failed` on a live assembly (Flight Core:
/// configure failures abort bootstrap entirely).
struct FailingServiceModule: FlightModule {
    struct Boom: Error, CustomStringConvertible {
        var description: String { "boom: the flux capacitor de-fluxed" }
    }

    struct FailingService: Service {
        func run() async throws {
            throw Boom()
        }
    }

    var service: (any Service)? { FailingService() }
}
