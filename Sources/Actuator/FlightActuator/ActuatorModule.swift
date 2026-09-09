import FlightCore
import Synchronization
import FlightWeb
import class Foundation.ProcessInfo

/// Flight Actuator's one entry point — a `FlightModule`, nothing more.
/// Registered like everything else:
///
///     try await Flight.bootstrap(
///         configuration: .load(),
///         modules: [FlightWebModule<FlightTransport>.self, ActuatorModule.self]
///     )
///
/// ## Access gating
///
/// What gets registered is decided by ``ActuatorExposure``, resolved at
/// configuration time and never re-checked per request:
///
/// - ``ActuatorExposure/disabled`` — `configure` returns before touching the
///   container, so nothing exists in the route table to probe.
/// - ``ActuatorExposure/healthOnly`` — the default anywhere that has not
///   declared itself a development environment, including a deployment that
///   set nothing at all. The health routes are registered and the dashboard
///   is not.
/// - ``ActuatorExposure/full`` — health plus the `/actuator` dashboard,
///   which discloses the module list, every registered component's
///   fully-qualified type name, and failure messages. Unauthenticated
///   wherever it is on; putting authentication in front of it is the
///   deployment's job, and the module does not pretend otherwise.
public struct ActuatorModule: FlightModule {
    public static var dependencies: [any FlightModule.Type] { [] }

    /// Qualifier under which the gate's environment is registered for the
    /// controller to report — namespaced so it can never collide with an
    /// app's own unqualified `FlightEnvironment` registration.
    static let environmentQualifier = "flight.actuator"

    /// Holds the controller the routes serve from.
    ///
    /// The routes are values, built when the module is; the controller needs
    /// the container it introspects, which only exists at `configure`. So the
    /// routes close over this box and `configure` fills it — which is what
    /// replaced `context.resolve(ActuatorController.self)` in every handler.
    final class ControllerBox: @unchecked Sendable {
        private let storage = Mutex<ActuatorController?>(nil)
        func set(_ controller: ActuatorController) { storage.withLock { $0 = controller } }
        func get() throws -> ActuatorController {
            guard let controller = storage.withLock({ $0 }) else {
                throw ActuatorNotConfigured()
            }
            return controller
        }
    }

    /// Thrown only if a route somehow serves before the module configured,
    /// which bootstrap's ordering makes unreachable — stated rather than
    /// force-unwrapped.
    struct ActuatorNotConfigured: Error, CustomStringConvertible {
        var description: String {
            "the actuator served a request before its module was configured"
        }
    }

    private let controller = ControllerBox()

    /// Where module health comes from — the shared registry the composition
    /// root threads in. Read at request time, so it reflects state as of the
    /// request, exactly as reading the container did.
    let health: ModuleHealthRegistry

    let environment: FlightEnvironment

    /// Bootstrap path: the environment comes from `FLIGHT_ENV`, read via
    /// `FlightEnvironment.current()`. This is the one sanctioned exception to
    /// "modules read config, not environment" (Flight Config) — Actuator
    /// legitimately needs the raw environment to decide whether it is
    /// allowed to exist at all.
    public init() {
        self.init(processEnvironment: ProcessInfo.processInfo.environment)
    }

    /// The shape the composition root uses: FLIGHT_ENV for the environment,
    /// `actuator.format` from configuration, scanned components from the
    /// generated `flightComponentDescriptors()`, health from the shared
    /// registry. Throws on a malformed `actuator.format`.
    public init(
        configuration: Configuration,
        components: [ComponentDescriptor] = [],
        health: ModuleHealthRegistry = ModuleHealthRegistry()
    ) throws {
        self.init(
            processEnvironment: ProcessInfo.processInfo.environment,
            components: components, health: health)
        try installController(
            format: configuration.getIfPresent("actuator.format", as: ActuatorFormat.self) ?? .ssr)
    }

    /// The same path with the process environment injected — how a test asks
    /// "what would an unset `FLIGHT_ENV` do" without mutating the real one.
    /// Uses the default `.ssr` format; the composer init above reads
    /// `actuator.format`.
    public init(
        processEnvironment: [String: String],
        components: [ComponentDescriptor] = [],
        health: ModuleHealthRegistry = ModuleHealthRegistry()
    ) {
        self.components = components
        self.health = health
        self.environment = .current(from: processEnvironment)
        self.exposureOverride = nil
        // An unset FLIGHT_ENV resolves to `dev`, which is in the dashboard
        // allowlist — so a production deployment that never set it used to
        // serve the full unauthenticated dashboard. Whether the environment
        // was *stated* is a different question from what it resolved to, and
        // it is the one the gate needs.
        self.isEnvironmentDeclared = processEnvironment["FLIGHT_ENV"].map { !$0.isEmpty } ?? false
        self.routes = Self.makeRoutes(
            exposure: try? ActuatorExposure.resolve(
                environment: environment, isEnvironmentDeclared: isEnvironmentDeclared),
            controller: controller)
        installController(format: .ssr)
    }

    /// Explicit-environment initializer — the test seam (`TestContainer.build`
    /// honors ready-made instances), and an escape hatch for embedders that
    /// resolve the environment some other way.
    public init(
        environment: FlightEnvironment,
        components: [ComponentDescriptor] = [],
        health: ModuleHealthRegistry = ModuleHealthRegistry()
    ) {
        self.components = components
        self.health = health
        self.environment = environment
        self.exposureOverride = nil
        // Naming the environment in code is a declaration, the same as
        // setting FLIGHT_ENV.
        self.isEnvironmentDeclared = true
        self.routes = Self.makeRoutes(
            exposure: try? ActuatorExposure.resolve(
                environment: environment, isEnvironmentDeclared: true),
            controller: controller)
        installController(format: .ssr)
    }

    /// Explicit exposure, bypassing both the environment allowlist and
    /// `FLIGHT_ACTUATOR_EXPOSURE` — the seam tests use instead of mutating
    /// the real process environment.
    public init(
        environment: FlightEnvironment,
        exposure: ActuatorExposure,
        components: [ComponentDescriptor] = [],
        health: ModuleHealthRegistry = ModuleHealthRegistry()
    ) {
        self.components = components
        self.health = health
        self.environment = environment
        self.exposureOverride = exposure
        self.isEnvironmentDeclared = true
        self.routes = Self.makeRoutes(exposure: exposure, controller: controller)
        installController(format: .ssr)
    }

    private let exposureOverride: ActuatorExposure?
    private let isEnvironmentDeclared: Bool

    /// Resolved once, when the module is built, so `routes` can be a stored
    /// value — and kept as a `Result` because `FlightModule` requires a
    /// non-throwing `init()`. A malformed `FLIGHT_ACTUATOR_EXPOSURE` still
    /// fails bootstrap: `configure` rethrows it below, and nothing serves
    /// before every module has configured.
    private var resolvedExposure: Result<ActuatorExposure, any Error> {
        Result {
            try exposureOverride
                ?? ActuatorExposure.resolve(
                    environment: environment, isEnvironmentDeclared: isEnvironmentDeclared)
        }
    }

    /// The actuator's endpoints, as values.
    ///
    /// §2.9a's case: whether these exist at all is decided by `FLIGHT_ENV` at
    /// bootstrap, so no build-time scan can answer it — which is why they
    /// carried `flight:hand-registered` markers when they were imperative
    /// `registerRoute` calls. As values the gate is an ordinary `if`, and the
    /// composition root collects them like any other contribution.
    ///
    /// Each handler resolves the controller from the request's context: a
    /// lock-free singleton lookup, not reconstruction.
    public let routes: [RouteRegistration]

    /// Every component the build scanned, handed over by the composition
    /// root. Empty is legal — an application with no components has nothing
    /// for the dashboard to list.
    public let components: [ComponentDescriptor]

    /// Actuator's own controller, which no application's build scans because
    /// this module registers it. A module knows what it provides, so it says
    /// so rather than relying on the dashboard to notice a registration.
    static let ownComponents: [ComponentDescriptor] = [
        ComponentDescriptor(
            typeName: "FlightActuator.ActuatorController", scope: .singleton,
            sourceModule: "ActuatorModule", qualifier: nil, stereotype: .controller)
    ]

    /// Stored rather than computed, because the composition root reads what a
    /// module *holds*: a computed property is excluded from that scan, which
    /// is what keeps `var service` from being taken as a contribution.
    private static func makeRoutes(
        exposure: ActuatorExposure?, controller: ControllerBox
    ) -> [RouteRegistration] {
        guard let exposure, exposure.publishesHealth else { return [] }
        // Health is published wherever the actuator is enabled at all: an
        // orchestrator needs a probe in production, and the old
        // all-or-nothing gate is why production had none.
        var routes: [RouteRegistration] = [
            RouteRegistration(method: "GET", path: "/actuator/health", source: "FlightActuator") {
                context in try await controller.get().health(context)
            },
            // Liveness and readiness are different questions, and one endpoint
            // answering both got one of them wrong whichever way it was wired:
            // a module that has not started yet must not count against
            // liveness (a slow pod restarts into the same slow start, forever)
            // and must count against readiness.
            RouteRegistration(
                method: "GET", path: "/actuator/health/live", source: "FlightActuator"
            ) { context in
                try await controller.get().liveness(context)
            },
            RouteRegistration(
                method: "GET", path: "/actuator/health/ready", source: "FlightActuator"
            ) { context in
                try await controller.get().readiness(context)
            },
        ]
        // The dashboard discloses the module list, every registered
        // component's fully-qualified type name, and failure messages. It is
        // published only where the exposure says so — an unrecognized
        // environment does not get it.
        if exposure.publishesDashboard {
            routes.append(
                RouteRegistration(method: "GET", path: "/actuator", source: "FlightActuator") {
                    context in
                    try await controller.get().dashboard(context)
                })
        }
        return routes
    }

    /// Builds the controller into the box the routes serve from, when the
    /// exposure publishes anything. Called from `init` — there is no container
    /// and no `configure`; the module holds what it needs.
    ///
    /// `format` is read once here (the "read at bootstrap" semantics the
    /// freeze()-time factory used to give it). A malformed `actuator.format`
    /// throws, failing composition.
    private func installController(format: ActuatorFormat) {
        guard let exposure = try? resolvedExposure.get(), exposure.publishesHealth else { return }
        controller.set(
            ActuatorController(
                components: components + Self.ownComponents,
                health: { [health] in health.statuses() },
                environment: environment,
                format: format))
    }
}
