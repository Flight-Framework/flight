import ServiceLifecycle

/// The one extension point. Deliberately the smallest possible surface:
/// register components in `configure`, optionally hand one `Service` to the
/// lifecycle group. If a future starter seems to need more, extend this
/// deliberately — never via a side channel.
public protocol FlightModule {
    /// Bootstrap instantiates modules itself }`),
    /// so conformances must be constructible without arguments. Configuration
    /// reaches modules through the container (bootstrap registers
    /// `Configuration` before any module configures), not through init.
    init()

    /// Modules that must have already run `configure(_:)` before this one.
    /// Forms a DAG resolved once at bootstrap — deterministic and checkable,
    /// not "hope registration order happens to work."
    static var dependencies: [any FlightModule.Type] { get }

    /// Pure registration. No I/O, no long-running work. Runs during the
    /// container's registration phase, strictly serial across the module DAG.
    func configure(_ container: Container) throws

    /// Present only if this module owns a long-running component. Handed to
    /// the app-wide ServiceLifecycle `ServiceGroup` at bootstrap.
    var service: (any Service)? { get }

    /// What it means when this module's `service` *returns* from `run()`
    /// without throwing. Deliberate the contract extension : without it, bootstrap could only host run-until-shutdown
    /// services — a bounded one-shot service (batch job, queue drain) would
    /// fail the whole group on completion.
    var serviceCompletion: ServiceCompletionPolicy { get }
}

/// Bootstrap maps this onto ServiceLifecycle's per-service
/// `successTerminationBehavior`. A thrown error is always a failure
/// regardless of this policy.
public enum ServiceCompletionPolicy: Sendable, Equatable {
    /// The service is expected to run for the app's whole lifetime (an HTTP
    /// server). Returning from `run()` is a failure: the group cancels and
    /// `bootstrap` rethrows. The default.
    case failsApp
    /// The service performs a bounded unit of work. Returning from `run()`
    /// gracefully shuts down the app.
    case endsApp
}

extension FlightModule {
    public static var dependencies: [any FlightModule.Type] { [] }
    public var service: (any Service)? { nil }
    public var serviceCompletion: ServiceCompletionPolicy { .failsApp }

    /// Stable display name used for ComponentDescriptor.sourceModule and
    /// ModuleStatus.moduleName.
    public static var moduleName: String { String(describing: Self.self) }
}

// MARK: - Module health

/// Tracked externally by bootstrap — `FlightModule` stays unchanged. Coarse
/// by design; finer-grained state is a deliberate additive extension to make
/// once a real need appears.
public enum ModuleHealth: Sendable {
    case notStarted
    case running
    case failed(any Error)

    /// `true` when the module's service threw.
    public var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

extension ModuleHealth: Equatable {
    /// Two failures are equal when their messages match.
    ///
    /// `any Error` cannot synthesize `Equatable`, and comparing existentials
    /// by identity would make every failure unequal to every other — which is
    /// useless in the place this is actually compared: a test asserting that a
    /// module reported the failure it was supposed to.
    public static func == (lhs: ModuleHealth, rhs: ModuleHealth) -> Bool {
        switch (lhs, rhs) {
        case (.notStarted, .notStarted), (.running, .running):
            return true
        case (.failed(let lhsError), .failed(let rhsError)):
            return String(describing: lhsError) == String(describing: rhsError)
        default:
            return false
        }
    }
}

public struct ModuleStatus: Sendable {
    public let moduleName: String
    public let health: ModuleHealth
}

// MARK: - Module DAG resolution

public enum ModuleGraphError: Error, CustomStringConvertible, Sendable {
    case cycle([String])
    public var description: String {
        switch self {
        case .cycle(let names):
            return "FlightModule dependency cycle: \(names.joined(separator: " → "))"
        }
    }
}

/// Deterministic topological order over the module DAG.
///
/// Properties, all load-bearing:
/// - Dependencies always precede dependents.
/// - Order is stable: modules are visited in the order given, and each
/// module's dependencies in their declared order — same input, same output,
/// every run. It is deterministic and checkable.
/// - Transitive dependencies are auto-included: listing `WebModule` pulls in
/// everything `WebModule.dependencies` declares, recursively. A module you
/// depend on but forgot to list is a wiring bug this removes by design.
/// - Cycles are an error naming the full chain.
public func _flightResolveModuleOrder(_ modules: [any FlightModule.Type]) throws
    -> [any FlightModule.Type]
{
    var ordered: [any FlightModule.Type] = []
    var finished: Set<ObjectIdentifier> = []
    var inProgress: Set<ObjectIdentifier> = []
    var stack: [String] = []

    func visit(_ module: any FlightModule.Type) throws {
        let id = ObjectIdentifier(module)
        if finished.contains(id) { return }
        if inProgress.contains(id) {
            throw ModuleGraphError.cycle(stack + [module.moduleName])
        }
        inProgress.insert(id)
        stack.append(module.moduleName)
        for dependency in module.dependencies {
            try visit(dependency)
        }
        stack.removeLast()
        inProgress.remove(id)
        finished.insert(id)
        ordered.append(module)
    }

    for module in modules {
        try visit(module)
    }
    return ordered
}
