import FlightCore
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

    let environment: FlightEnvironment

    /// Bootstrap path: the environment comes from `FLIGHT_ENV`, read via
    /// `FlightEnvironment.current()`. This is the one sanctioned exception to
    /// "modules read config, not environment" (Flight Config) — Actuator
    /// legitimately needs the raw environment to decide whether it is
    /// allowed to exist at all.
    public init() {
        self.init(processEnvironment: ProcessInfo.processInfo.environment)
    }

    /// The same path with the process environment injected — how a test asks
    /// "what would an unset `FLIGHT_ENV` do" without mutating the real one.
    public init(processEnvironment: [String: String]) {
        self.environment = .current(from: processEnvironment)
        self.exposureOverride = nil
        // An unset FLIGHT_ENV resolves to `dev`, which is in the dashboard
        // allowlist — so a production deployment that never set it used to
        // serve the full unauthenticated dashboard. Whether the environment
        // was *stated* is a different question from what it resolved to, and
        // it is the one the gate needs.
        self.isEnvironmentDeclared = processEnvironment["FLIGHT_ENV"].map { !$0.isEmpty } ?? false
    }

    /// Explicit-environment initializer — the test seam (`TestContainer.build`
    /// honors ready-made instances), and an escape hatch for embedders that
    /// resolve the environment some other way.
    public init(environment: FlightEnvironment) {
        self.environment = environment
        self.exposureOverride = nil
        // Naming the environment in code is a declaration, the same as
        // setting FLIGHT_ENV.
        self.isEnvironmentDeclared = true
    }

    /// Explicit exposure, bypassing both the environment allowlist and
    /// `FLIGHT_ACTUATOR_EXPOSURE` — the seam tests use instead of mutating
    /// the real process environment.
    public init(environment: FlightEnvironment, exposure: ActuatorExposure) {
        self.environment = environment
        self.exposureOverride = exposure
        self.isEnvironmentDeclared = true
    }

    private let exposureOverride: ActuatorExposure?
    private let isEnvironmentDeclared: Bool

    public func configure(_ container: Container) throws {
        // Whether a route is registered at all has to be decided here, and
        // registration-phase code cannot resolve `Configuration` — so the
        // override arrives the same way `FLIGHT_ENV` does.
        let exposure =
            try exposureOverride
            ?? ActuatorExposure.resolve(
                environment: environment, isEnvironmentDeclared: isEnvironmentDeclared)
        guard exposure.publishesHealth else { return }

        // The environment the gate ran against, for the dashboard to report.
        container.register(
            FlightEnvironment.self,
            qualifier: Self.environmentQualifier,
            scope: .singleton
        ) { [environment] _ in environment }

        // ActuatorController is a plain struct, not @Controller (see its
        // file for why) — registered here by hand, exactly as the design
        // doc's sketch shows. The factory runs once, at freeze()'s
        // eager singleton construction, which is what gives `format` its
        // "read once at bootstrap" semantics without @ConfigValue.
        // `container` is the same instance being configured — no
        // self-registration needed for the controller to hold a reference
        // to it.
        container.register(ActuatorController.self, scope: .singleton, stereotype: .controller) { [environment] c in
            // getIfPresent, not get(_:default:) — the latter is non-throwing
            // and fatalErrors on a malformed *present* value; getIfPresent
            // throws instead, so a malformed value still fails module
            // configuration loudly rather than trapping the process.
            // The same distinction @ConfigValue's own `default:` expansion
            // relies on (getIfPresent's doc comment).
            let format = try c.resolve(Configuration.self)
                .getIfPresent("actuator.format", as: ActuatorFormat.self) ?? .ssr
            return ActuatorController(container: c, environment: environment, format: format)
        }

        // The route itself, through the same escape hatch @GetRoute sits
        // beside (Flight Web's registerRoute). Resolving the controller
        // here is a lock-free singleton lookup, not reconstruction — the
        // factory above already ran at freeze(), before any request.
        // Health is published wherever the actuator is enabled at all: an
        // orchestrator needs a probe in production, and the old all-or-nothing
        // gate is why production had none.
        container.registerRoute(.get, "/actuator/health", source: "FlightActuator") { context in
            try await context.resolve(ActuatorController.self).health(context)
        }
        // Liveness and readiness are different questions, and one endpoint
        // answering both got one of them wrong whichever way it was wired: a
        // module that has not started yet must not count against liveness (a
        // slow pod restarts into the same slow start, forever) and must count
        // against readiness.
        container.registerRoute(.get, "/actuator/health/live", source: "FlightActuator") {
            context in
            try await context.resolve(ActuatorController.self).liveness(context)
        }
        container.registerRoute(.get, "/actuator/health/ready", source: "FlightActuator") {
            context in
            try await context.resolve(ActuatorController.self).readiness(context)
        }

        // The dashboard discloses the module list, every registered
        // component's fully-qualified type name, and failure messages. It is
        // registered only where the exposure says so — an unrecognized
        // environment does not get it.
        guard exposure.publishesDashboard else { return }
        container.registerRoute(.get, "/actuator", source: "FlightActuator") { context in
            try await context.resolve(ActuatorController.self).dashboard(context)
        }
    }
}
