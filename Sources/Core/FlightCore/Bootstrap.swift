import Logging
import ServiceLifecycle

/// Everything `bootstrap` builds before handing off to ServiceLifecycle.
/// Exposed so tests (and embedders like a CLI harness) can run the assembly
/// steps without entering a never-returning `ServiceGroup.run()`.
public struct AssembledApplication: Sendable {
    public let container: Container
    public let services: [AssembledService]
    public let moduleOrder: [String]
}

/// One module's service, health-wrapped, with the module's declared
/// completion policy — bootstrap maps the policy onto ServiceLifecycle's
/// `successTerminationBehavior`.
public struct AssembledService: Sendable {
    public let moduleName: String
    public let service: any Service
    public let completion: ServiceCompletionPolicy
    /// Where this service sits in the start/shutdown order — see
    /// ``ServiceShutdownPhase``.
    public let shutdownPhase: ServiceShutdownPhase

    public init(
        moduleName: String,
        service: any Service,
        completion: ServiceCompletionPolicy,
        shutdownPhase: ServiceShutdownPhase = .standard
    ) {
        self.moduleName = moduleName
        self.service = service
        self.completion = completion
        self.shutdownPhase = shutdownPhase
    }
}

public enum BootstrapError: Error, CustomStringConvertible {
    case moduleConfigurationFailed(module: String, underlying: any Error)
    case singletonConstructionFailed(underlying: any Error)

    /// Two registrations claimed the same type and qualifier.
    ///
    /// Usually a generated existential bridge colliding with a hand-written
    /// registration. Give one of them a qualifier.
    case duplicateRegistration(String)

    /// A module named only by its type takes what it provides as initializer
    /// parameters — see ``FlightModule/isTypeConstructible``.
    case moduleRequiresConstruction(module: String)

    public var description: String {
        switch self {
        case .moduleConfigurationFailed(let module, let underlying):
            return "Module \(module) failed during configure(_:): \(underlying)"
        case .singletonConstructionFailed(let underlying):
            return "Eager singleton construction failed at freeze(): \(underlying)"
        case .duplicateRegistration(let key):
            return """
                Duplicate registration for \(key). Two registrations claim the same type \
                and qualifier — often a generated existential bridge colliding with a \
                hand-written registration. Give one of them a qualifier.
                """
        case .moduleRequiresConstruction(let module):
            return """
                \(module) takes what it provides as initializer parameters, so it cannot be \
                built from its type. It was reached by name or through the module dependency \
                graph.

                Build it and pass the instance instead of the type. An application gets this \
                for free from the generated composition root — pass \
                `composedBy: flightComposeModules` to Flight.run, which is what `flight new` \
                writes. A test that names its own modules passes the built instance in the \
                same list.
                """
        }
    }
}

/// Steps 4–8 of the bootstrap sequence: container, module DAG, serial
/// registration, freeze, service collection. Steps 1–3 (environment, YAML,
/// Configuration assembly) belong to Flight Config; this function receives
/// their output. Config must be fully resolved before modules configure —
/// that ordering is enforced here by the signature itself.
///
/// Internal: `Flight.assemble` is the public spelling. This was public with
/// no caller anywhere outside FlightCore, duplicating that surface under a
/// name nothing was meant to type.
func _flightAssemble(
    configuration: Configuration,
    modules: [any FlightModule.Type]
) throws -> AssembledApplication {
    // Step 5, and the reason this overload exists: a module named only as a
    // type has to be instantiated here, so it must be constructible with no
    // arguments. The instance overload below is for a caller that already
    // built them — which is what a generated composition root does, and what
    // lets a module take what it needs as initializer parameters
    // (COMPOSITION-MIGRATION.md D11).
    let ordered = try _flightResolveModuleOrder(modules)
    return try _flightAssemble(
        configuration: configuration,
        moduleInstances: Flight.instantiateModules(ordered))
}

/// The same assembly from modules already built and already ordered.
///
/// Ordered, because resolving the DAG is what the type-based overload uses
/// the types *for*: given instances, there is nothing left to sort by. A
/// caller supplying these has the order already — a generated composition
/// root gets it from the same `dependencies` walk, at build time — and
/// supplying them out of order is the one mistake this signature cannot
/// catch. That is the trade: the DAG moves to the build, and with it the
/// requirement that a module be constructible with no arguments.
func _flightAssemble(
    configuration: Configuration,
    moduleInstances instances: [any FlightModule]
) throws -> AssembledApplication {
    let container = Container()  // step 4

    let names = instances.map { type(of: $0).moduleName }
    container.beginHealthTracking(moduleNames: names)

    // Configuration is itself a component: modules read config values by resolving
    // it (directly or via @ConfigValue-generated code) during configure.
    container.register(Configuration.self, scope: .singleton) { _ in configuration }

    var services:
        [(
            moduleName: String, service: any Service, completion: ServiceCompletionPolicy,
            phase: ServiceShutdownPhase
        )] = []
    for (name, module) in zip(names, instances) {  // step 6
        container.currentSourceModule = name
        do {
            try module.configure(container)
        } catch {
            container.currentSourceModule = "<direct>"
            container.setHealth(name, .failed(error))
            throw BootstrapError.moduleConfigurationFailed(module: name, underlying: error)
        }
        // : registration-only modules are "running" the moment they're
        // configured; service-owning modules stay .running unless their
        // Service later terminates with an error (see HealthTrackingService).
        container.setHealth(name, .running)
        if let service = module.service {  // step 8 (collected here)
            services.append((name, service, module.serviceCompletion, module.serviceShutdownPhase))
        }
    }
    container.currentSourceModule = "<direct>"

    do {
        try container.freeze()  // step 7
    } catch {
        throw BootstrapError.singletonConstructionFailed(underlying: error)
    }

    // Sorted by phase, stably, so the DAG's order still decides within a
    // phase. `ServiceGroup` starts in this order and shuts down in reverse,
    // which is what puts infrastructure up first and down last, and the
    // inbound transport up last and down first. Without this the order was
    // whatever order the application listed its modules in, and the shape
    // every example uses shut the database down underneath a server that was
    // still serving — see `ServiceShutdownPhase`.
    let wrapped =
        services
        .enumerated()
        .sorted { left, right in
            left.element.phase == right.element.phase
                ? left.offset < right.offset
                : left.element.phase < right.element.phase
        }
        .map { entry in
            AssembledService(
                moduleName: entry.element.moduleName,
                service: HealthTrackingService(
                    moduleName: entry.element.moduleName, inner: entry.element.service,
                    container: container),
                completion: entry.element.completion,
                shutdownPhase: entry.element.phase
            )
        }
    return AssembledApplication(
        container: container,
        services: wrapped,
        moduleOrder: names
    )
}

/// Full bootstrap: assemble, then hand off to ServiceLifecycle. Signal
/// handling, graceful shutdown, and cascading shutdown-on-failure are
/// ServiceLifecycle's problem from here — not Flight's to reinvent.
///
/// Returns only when the ServiceGroup finishes (shutdown or failure). Apps
/// with no long-running services return immediately after assembly — a valid
/// shape for one-shot CLI-style Flight apps.
func _flightBootstrap(
    configuration: Configuration,
    modules: [any FlightModule.Type],
    logger: Logger = Logger(label: "flight.bootstrap")
) async throws {
    try await _flightBootstrap(
        configuration: configuration,
        assembled: _flightAssemble(configuration: configuration, modules: modules),
        logger: logger)
}

/// The same bootstrap from modules a caller already built, in dependency
/// order — what a generated composer supplies.
func _flightBootstrap(
    configuration: Configuration,
    moduleInstances instances: [any FlightModule],
    logger: Logger = Logger(label: "flight.bootstrap")
) async throws {
    try await _flightBootstrap(
        configuration: configuration,
        assembled: _flightAssemble(configuration: configuration, moduleInstances: instances),
        logger: logger)
}

private func _flightBootstrap(
    configuration: Configuration,
    assembled app: AssembledApplication,
    logger: Logger
) async throws {
    logger.info(
        "flight assembled",
        metadata: [
            "modules": .array(app.moduleOrder.map { .string($0) }),
            "components": .stringConvertible(app.container.allRegistrations().count),
            "services": .stringConvertible(app.services.count),
        ])

    guard !app.services.isEmpty else {
        logger.info("no long-running services; bootstrap complete")
        return
    }

    let group = ServiceGroup(  // step 9
        configuration: .init(
            services: app.services.map { entry in
                ServiceGroupConfiguration.ServiceConfiguration(
                    service: entry.service,
                    // .failsApp → .cancelGroup: a server returning early is a
                    // failure. .endsApp → graceful shutdown: bounded work done.
                    successTerminationBehavior: entry.completion == .endsApp
                        ? .gracefullyShutdownGroup
                        : .cancelGroup
                )
            },
            gracefulShutdownSignals: [.sigterm, .sigint],
            logger: logger
        )
    )
    try await group.run()
}

/// Maps a Service's termination onto ModuleHealth with zero
/// instrumentation required from module authors — bootstrap observes it from
/// the outside, which is the whole point of tracking health externally.
struct HealthTrackingService: Service {
    let moduleName: String
    let inner: any Service
    let container: Container

    func run() async throws {
        do {
            try await inner.run()
        } catch {
            container.setHealth(moduleName, .failed(error))
            throw error
        }
    }
}
