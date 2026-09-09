import FlightCore
import Foundation
import ServiceLifecycle

/// Registers the scheduler.
///
/// ```swift
/// try await Flight.bootstrap(
///     configuration: try Configuration.load(),
///     modules: [FlightSchedulerModule.self, AppModule.self]
/// )
/// ```
///
/// A struct holding what it provides: the jobs exist before any container
/// does, so `configure` registers only the status the actuator reads.
///
/// Registers no coordinator of its own. A deployment that needs `.once` to
/// mean once across several servers registers a ``JobCoordinator`` from a
/// module that has something to coordinate *through* — a database, a cache —
/// exactly as a distributed PubSub deployment registers an adapter.
public struct FlightSchedulerModule: FlightModule {

    /// Every scheduled job in the application, as values. The generated
    /// `flightScheduledJobs(_:)` supplies this target's, closing over the
    /// component the graph already built; a module declaring its own jobs
    /// contributes them the same way.
    public let jobs: [ScheduledJobRegistration]

    /// What makes `.once` mean once across every server rather than once per
    /// server. Nil is the single-node case, which is the default — and the
    /// scheduler says so, loudly, at startup.
    ///
    /// A parameter rather than a container lookup: whether a deployment has
    /// something to coordinate *through* is a fact about how it was composed.
    private let coordinator: (any JobCoordinator)?

    /// Reported by Actuator; owned here.
    public let status = SchedulerStatus()

    /// Nothing to build it from a type alone would be *wrong* — a scheduler
    /// with no jobs is a legal application — so `init()` stays usable and
    /// this module keeps `isTypeConstructible` true.
    public init() {
        self.init(jobs: [], coordinator: nil)
    }

    public init(jobs: [ScheduledJobRegistration] = [], coordinator: (any JobCoordinator)? = nil) {
        self.jobs = jobs
        self.coordinator = coordinator
    }

    /// Built from what this module holds. It used to be built from a stashed
    /// `Container` and collect its jobs at `run()`, because the jobs were
    /// registrations gathered post-`freeze()`.
    public var service: (any Service)? {
        SchedulerService(jobs: jobs, coordinator: coordinator, status: status)
    }
}
