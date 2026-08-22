import FlightCore
import FlightWeb

/// Flight Actuator's one entry point — a `FlightModule`, nothing more (§2).
/// Registered like everything else:
///
///     try await bootstrap(
///         configuration: .load(),
///         modules: [FlightWebModule<FlightTransport>.self, ActuatorModule.self]
///     )
///
/// ## Access gating (§4.1)
///
/// In `.prod` the routes are simply **not registered** — `configure` returns
/// before anything touches the container, so `/actuator` does not exist in
/// the route table at all. There is nothing to probe or misconfigure: this is
/// a non-choice, not a runtime auth check with a failure mode. Prod access is
/// a seam reserved for Flight Security (§4.2) and deliberately not built.
public struct ActuatorModule: FlightModule {
    public static var dependencies: [any FlightModule.Type] { [] }

    /// Qualifier under which the gate's environment is registered for the
    /// controller to report — namespaced so it can never collide with an
    /// app's own unqualified `FlightEnvironment` registration.
    static let environmentQualifier = "flight.actuator"

    let environment: FlightEnvironment

    /// Bootstrap path: the environment comes from `FLIGHT_ENV`, read via
    /// `FlightEnvironment.current()`. This is the one sanctioned exception to
    /// "modules read config, not environment" (Flight Config §4) — Actuator
    /// legitimately needs the raw environment to decide whether it is
    /// allowed to exist at all.
    public init() {
        self.init(environment: .current())
    }

    /// Explicit-environment initializer — the test seam (`TestContainer.build`
    /// honors ready-made instances), and an escape hatch for embedders that
    /// resolve the environment some other way.
    public init(environment: FlightEnvironment) {
        self.environment = environment
    }

    public func configure(_ container: Container) throws {
        guard environment != .prod else { return }  // §4.1: no routes registered at all

        // The environment the gate ran against, for the dashboard to report.
        container.register(
            FlightEnvironment.self,
            qualifier: Self.environmentQualifier,
            scope: .singleton
        ) { [environment] _ in environment }

        // ActuatorController is a plain struct, not @Controller (see its
        // file for why) — registered here by hand, exactly as the design
        // doc's §4.1 sketch shows. The factory runs once, at freeze()'s
        // eager singleton construction, which is what gives `format` its
        // "read once at bootstrap" semantics (§5) without @ConfigValue.
        // `container` is the same instance being configured — no
        // self-registration needed for the controller to hold a reference
        // to it.
        container.register(ActuatorController.self, scope: .singleton, stereotype: .controller) { [environment] c in
            // getIfPresent, not get(_:default:) — the latter is non-throwing
            // and fatalErrors on a malformed *present* value; getIfPresent
            // throws instead, so a malformed value still fails module
            // configuration loudly (§5) rather than trapping the process.
            // The same distinction @ConfigValue's own `default:` expansion
            // relies on (getIfPresent's doc comment).
            let format = try c.resolve(Configuration.self)
                .getIfPresent("actuator.format", as: ActuatorFormat.self) ?? .ssr
            return ActuatorController(container: c, environment: environment, format: format)
        }

        // The route itself, through the same escape hatch @GetMapping sits
        // beside (Flight Web §4's registerRoute). Resolving the controller
        // here is a lock-free singleton lookup, not reconstruction — the
        // factory above already ran at freeze(), before any request.
        container.registerRoute(.get, "/actuator", source: "FlightActuator") { context in
            try await context.resolve(ActuatorController.self).dashboard(context)
        }
    }
}
