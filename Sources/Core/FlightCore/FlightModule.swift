import ServiceLifecycle

/// The one extension point. Deliberately the smallest possible surface:
/// declare the modules this one depends on, hold what this module provides as
/// stored properties, and optionally hand one `Service` to the lifecycle
/// group. If a future starter seems to need more, extend this deliberately —
/// never via a side channel.
public protocol FlightModule {
    /// Modules that must be *included* when this one is — the composition root
    /// pulls in prerequisites so naming one module names its stack. Not an
    /// ordering constraint: construction order comes from the value flow the
    /// generator resolves at build time.
    static var dependencies: [any FlightModule.Type] { get }

    /// Present only if this module owns a long-running component. Handed to
    /// the app-wide ServiceLifecycle `ServiceGroup` at bootstrap.
    var service: (any Service)? { get }

    /// When this module's service is shut down, relative to the others.
    ///
    /// `ServiceGroup` starts services in order and shuts them down in
    /// *reverse* order, so the array's order is a shutdown order read
    /// backwards. Bootstrap builds that array from the module DAG, which
    /// orders modules by `dependencies` — and nothing in the DAG says that
    /// the HTTP server depends on the database pool, because it does not:
    /// the *requests* do. So the order came from however the application
    /// happened to list its modules, and the shape every example uses —
    /// `modules: [FlightWebModule<FlightTransport>.self, AppModule.self]` —
    /// put the transport first, which made it shut down **last**: the pools
    /// closed underneath a server still serving requests, and a request
    /// holding a connection at that moment took the process down with
    /// "PostgresConnection deinitialized before being closed".
    ///
    /// A phase says what the DAG cannot. Inbound services stop first (no new
    /// work, drain what is in flight), then ordinary services, then the
    /// infrastructure everything else was using.
    var serviceShutdownPhase: ServiceShutdownPhase { get }

    /// What it means when this module's `service` *returns* from `run()`
    /// without throwing.
    ///
    /// A deliberate extension of ServiceLifecycle's contract: without it,
    /// bootstrap could only host run-until-shutdown services, and a bounded
    /// one-shot service — a batch job, a queue drain — would fail the whole
    /// group by finishing.
    var serviceCompletion: ServiceCompletionPolicy { get }
}

/// Where a module's service sits in the shutdown order.
///
/// Ordered so that a lower phase shuts down *later*: bootstrap sorts the
/// service array by phase ascending, and `ServiceGroup` shuts down in
/// reverse. Startup order falls out correctly at the same time —
/// infrastructure is started before the server that will use it.
public enum ServiceShutdownPhase: Int, Sendable, Comparable, CaseIterable {
    /// Pools, buses, caches — everything a request path borrows. Started
    /// first, shut down last.
    case infrastructure = 0
    /// The default: schedulers, background workers, application services.
    case standard = 1
    /// Accepts work from outside — an HTTP transport, a queue consumer.
    /// Started last, shut down **first**, so nothing new arrives while the
    /// rest of the system is being taken apart.
    case inbound = 2

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
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
    public var serviceShutdownPhase: ServiceShutdownPhase { .standard }

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
