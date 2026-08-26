import FlightActuator
import FlightCore
import FlightWeb
import ServiceLifecycle

// Shared test fixtures. All go through public Flight contracts only —
// Actuator is a consumer of the stack, and so are its tests.

/// A module registering one bean of each stereotype/scope combination the
/// dashboard needs to distinguish, plus a qualified duplicate-type pair.
struct SampleAppModule: FlightModule {
    func configure(_ container: Container) throws {
        container.register(SampleService.self, scope: .singleton, stereotype: .service) { _ in
            SampleService()
        }
        container.register(SampleRepository.self, scope: .singleton, stereotype: .repository) { _ in
            SampleRepository()
        }
        container.register(SampleTransient.self, scope: .transient) { _ in
            SampleTransient()
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
    }
}

struct SampleService: Sendable {}
struct SampleRepository: Sendable {}
struct SampleTransient: Sendable {}
struct SampleQualified: Sendable {}
struct SampleMiddleware: Sendable {}
struct SampleSettings: Sendable {}

/// A module registering a bean whose qualifier is an XSS probe — the SSR
/// escaping tests feed the renderer through this.
struct HostileQualifierModule: FlightModule {
    static let hostileQualifier = #"<script>alert("pwned")</script>"#

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
