import FlightCore
import Foundation
import Logging
import ServiceLifecycle

/// The scheduler's long-running half: one task per job, running until
/// shutdown.
///
/// Registered by ``FlightSchedulerModule``. Starts after the container has
/// frozen, so every job's component is constructible and every schedule is
/// already known — a job whose dependencies are missing has failed the build
/// long before this runs.
public struct SchedulerService: Service, Sendable {
    private let container: Container
    private let clock: any SchedulerClock
    private let logger: Logger

    public init(
        container: Container,
        clock: any SchedulerClock = SystemSchedulerClock(),
        logger: Logger = Logger(label: "flight.scheduler")
    ) {
        self.container = container
        self.clock = clock
        self.logger = logger
    }

    public func run() async throws {
        let jobs = try container.collectScheduledJobs()
        let coordinator = Self.resolveCoordinator(in: container)
        let mode = Self.mode(for: coordinator)

        guard !jobs.isEmpty else {
            logger.info("scheduler started with no jobs")
            try await gracefulShutdown()
            return
        }

        // Loudly, at startup, the way PresenceMode does — because the failure
        // this guards against is silent. An operator who believes `.once`
        // means once and is running several servers without a coordinator
        // otherwise finds out from duplicated data.
        let onceJobs = jobs.filter { $0.scope == .once }
        logger.info(
            "scheduler started",
            metadata: [
                "jobs": .stringConvertible(jobs.count),
                "coordination": .string(mode.description),
                "run-once-jobs": .stringConvertible(onceJobs.count),
            ])
        if mode == .singleProcess && !onceJobs.isEmpty {
            logger.warning(
                """
                \(onceJobs.count) job(s) are set to run once per firing, and no distributed \
                JobCoordinator is registered. That is correct on a single server. If you run \
                more than one, every one of them will run these jobs — register a coordinator.
                """,
                metadata: ["jobs": .string(onceJobs.map(\.name).joined(separator: ", "))])
        }

        let runners = jobs.map {
            JobRunner(job: $0, coordinator: coordinator, clock: clock, logger: logger)
        }

        await withTaskGroup(of: Void.self) { group in
            for runner in runners {
                group.addTask { await runner.run() }
            }
            group.addTask {
                // Cancels the sibling tasks when the app shuts down.
                try? await gracefulShutdown()
            }
            await group.next()
            group.cancelAll()
        }
        logger.info("scheduler stopped")
    }

    /// A coordinator if one is registered, the single-process one otherwise.
    static func resolveCoordinator(in container: Container) -> any JobCoordinator {
        do {
            return try container.resolve((any JobCoordinator).self)
        } catch let error as ResolutionError {
            // Absent coordinator = single-process deployment, the common case.
            // Any other resolution failure is a real wiring bug and should
            // not be swallowed.
            guard case .notRegistered = error else { return LocalJobCoordinator() }
            return LocalJobCoordinator()
        } catch {
            return LocalJobCoordinator()
        }
    }

    static func mode(for coordinator: any JobCoordinator) -> SchedulerMode {
        coordinator is LocalJobCoordinator
            ? .singleProcess : .coordinated(coordinator.describedKind)
    }
}
