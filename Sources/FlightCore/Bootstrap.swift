import Logging
import ServiceLifecycle

/// Everything `bootstrap` builds before handing off to ServiceLifecycle.
/// Exposed so tests (and embedders like a CLI harness) can run the assembly
/// steps without entering a never-returning `ServiceGroup.run()`.
public struct AssembledApplication {
    public let container: Container
    public let services: [AssembledService]
    public let moduleOrder: [String]
}

/// One module's service, health-wrapped, with the module's declared
/// completion policy — bootstrap maps the policy onto ServiceLifecycle's
/// `successTerminationBehavior`.
public struct AssembledService {
    public let moduleName: String
    public let service: any Service
    public let completion: ServiceCompletionPolicy
}

public enum BootstrapError: Error, CustomStringConvertible {
    case moduleConfigurationFailed(module: String, underlying: any Error)
    case singletonConstructionFailed(underlying: any Error)

    public var description: String {
        switch self {
        case .moduleConfigurationFailed(let module, let underlying):
            return "Module \(module) failed during configure(_:): \(underlying)"
        case .singletonConstructionFailed(let underlying):
            return "Eager singleton construction failed at freeze(): \(underlying)"
        }
    }
}

/// Steps 4–8 of the bootstrap sequence (§7): container, module DAG, serial
/// registration, freeze, service collection. Steps 1–3 (environment, YAML,
/// Configuration assembly) belong to Flight Config; this function receives
/// their output. Config must be fully resolved before modules configure —
/// that ordering is enforced here by the signature itself.
public func assemble(
    configuration: Configuration,
    modules: [any FlightModule.Type]
) throws -> AssembledApplication {
    let container = Container()                                   // step 4

    let ordered = try resolveModuleOrder(modules)                 // step 5
    container.beginHealthTracking(moduleNames: ordered.map { $0.moduleName })

    // Configuration is itself a component: modules read config values by resolving
    // it (directly or via @ConfigValue-generated code) during configure.
    container.register(Configuration.self, scope: .singleton) { _ in configuration }

    let instances = ordered.map { $0.init() }

    var services: [(moduleName: String, service: any Service, completion: ServiceCompletionPolicy)] = []
    for (moduleType, module) in zip(ordered, instances) {         // step 6
        let name = moduleType.moduleName
        container.currentSourceModule = name
        do {
            try module.configure(container)
        } catch {
            container.currentSourceModule = "<direct>"
            container.setHealth(name, .failed(error))
            throw BootstrapError.moduleConfigurationFailed(module: name, underlying: error)
        }
        // §6.1: registration-only modules are "running" the moment they're
        // configured; service-owning modules stay .running unless their
        // Service later terminates with an error (see HealthTrackingService).
        container.setHealth(name, .running)
        if let service = module.service {                          // step 8 (collected here)
            services.append((name, service, module.serviceCompletion))
        }
    }
    container.currentSourceModule = "<direct>"

    do {
        try container.freeze()                                     // step 7
    } catch {
        throw BootstrapError.singletonConstructionFailed(underlying: error)
    }

    let wrapped = services.map {
        AssembledService(
            moduleName: $0.moduleName,
            service: HealthTrackingService(moduleName: $0.moduleName, inner: $0.service, container: container),
            completion: $0.completion
        )
    }
    return AssembledApplication(
        container: container,
        services: wrapped,
        moduleOrder: ordered.map { $0.moduleName }
    )
}

/// Full bootstrap (§7): assemble, then hand off to ServiceLifecycle. Signal
/// handling, graceful shutdown, and cascading shutdown-on-failure are
/// ServiceLifecycle's problem from here — not Flight's to reinvent.
///
/// Returns only when the ServiceGroup finishes (shutdown or failure). Apps
/// with no long-running services return immediately after assembly — a valid
/// shape for one-shot CLI-style Flight apps.
public func bootstrap(
    configuration: Configuration,
    modules: [any FlightModule.Type],
    logger: Logger = Logger(label: "flight.bootstrap")
) async throws {
    let app = try assemble(configuration: configuration, modules: modules)
    logger.info("flight assembled", metadata: [
        "modules": .array(app.moduleOrder.map { .string($0) }),
        "components": .stringConvertible(app.container.allRegistrations().count),
        "services": .stringConvertible(app.services.count),
    ])

    guard !app.services.isEmpty else {
        logger.info("no long-running services; bootstrap complete")
        return
    }

    let group = ServiceGroup(                                      // step 9
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

/// Maps a Service's termination onto ModuleHealth (§6.1) with zero
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
