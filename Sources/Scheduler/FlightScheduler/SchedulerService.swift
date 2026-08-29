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
        let coordinator = try Self.resolveCoordinator(in: container)
        let mode = Self.mode(for: coordinator)
        let status = try? container.resolve(SchedulerStatus.self)
        status?.setMode(mode)

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

        // The mirror image, and the nastier one because a coordinator *is*
        // present so the deployment believes it is covered. An interval's
        // firing instants are derived from this node's own last completion,
        // so no two nodes ever contend for the same claim key and every one
        // of them wins — the coordinator is consulted and always says yes.
        // Only a cron trigger has deployment-wide firing instants to claim.
        let uncoordinatableOnceJobs = jobs.filter {
            $0.scope == .once && $0.trigger.isNodeLocal
        }
        if mode != .singleProcess && !uncoordinatableOnceJobs.isEmpty {
            logger.error(
                """
                \(uncoordinatableOnceJobs.count) job(s) use an interval schedule and are set to \
                run once per firing, which a JobCoordinator cannot enforce: an interval is \
                measured from each node's own last run, so every node claims a different \
                firing and every claim succeeds. These jobs will run on every node. Give them \
                a cron expression to coordinate them, or mark them onEveryNode: true to say \
                that is intended.
                """,
                metadata: [
                    "jobs": .string(uncoordinatableOnceJobs.map(\.name).joined(separator: ", "))
                ])
        }

        // A zero or negative period is a firing every time round the loop
        // with no wait in between — a pinned core, not a schedule. Nothing
        // upstream can catch it: `Duration` is not a literal, so the macro
        // cannot evaluate it at build time. Startup is the next-earliest
        // place, and a named failure there beats finding it in production.
        for job in jobs {
            guard let period = job.trigger.intervalPeriod, period <= .zero else { continue }
            throw SchedulerStartupError.nonPositiveInterval(job: job.name, period: period)
        }

        let runners = jobs.map {
            JobRunner(
                job: $0, coordinator: coordinator, clock: clock, logger: logger, status: status)
        }

        await withTaskGroup(of: Exit.self) { group in
            for runner in runners {
                group.addTask { await runner.run(); return .runnerFinished }
            }
            group.addTask {
                // Cancels the sibling tasks when the app shuts down.
                try? await gracefulShutdown()
                return .shutdown
            }
            // Only shutdown ends the scheduler. A runner finishing on its own
            // means that job's schedule has run out — 30 February, a
            // date-bounded expression that has passed — and it says so in its
            // own log line. Cancelling the group on the *first* child to
            // finish made one such schedule silently stop every other job in
            // the process, which is the opposite of the isolation this
            // one-task-per-job design exists for.
            while let exit = await group.next() {
                if exit == .shutdown { break }
            }
            group.cancelAll()
        }
        logger.info("scheduler stopped")
    }

    /// Why the task group ended — the distinction that keeps one finished
    /// runner from being read as "the scheduler is done".
    private enum Exit: Sendable {
        case runnerFinished
        case shutdown
    }

    /// A coordinator if one is registered, the single-process one otherwise.
    ///
    /// Throws for any resolution failure that is not "nothing registered":
    /// a coordinator that is present but cannot be built is a wiring bug, and
    /// starting anyway in single-process mode would run every `.once` job on
    /// every node — the failure a coordinator is registered to prevent.
    static func resolveCoordinator(in container: Container) throws -> any JobCoordinator {
        do {
            return try container.resolve((any JobCoordinator).self)
        } catch let error as ResolutionError {
            // Absent coordinator = single-process deployment, the common case.
            guard case .notRegistered = error else { throw error }
            return LocalJobCoordinator()
        }
    }

    static func mode(for coordinator: any JobCoordinator) -> SchedulerMode {
        coordinator is LocalJobCoordinator
            ? .singleProcess : .coordinated(coordinator.describedKind)
    }
}

/// A job the scheduler refuses to start, reported before it runs rather than
/// as a symptom afterwards.
public enum SchedulerStartupError: Error, CustomStringConvertible, Sendable {
    /// `@Scheduled(every:)` with a period of zero or less.
    case nonPositiveInterval(job: String, period: Duration)
    /// A time zone identifier this machine's Foundation does not know.
    case unknownTimeZone(job: String, identifier: String)

    public var description: String {
        switch self {
        case .nonPositiveInterval(let job, let period):
            return """
                Scheduled job \(job) has an interval of \(period), which is not a schedule: \
                it would fire continuously with no wait in between. Give it a positive period.
                """
        case .unknownTimeZone(let job, let identifier):
            return """
                Scheduled job \(job) names time zone "\(identifier)", which this machine's \
                time zone database does not have. The @Scheduled macro checked it against the \
                build machine's, so the two disagree — usually a container image without \
                tzdata installed.
                """
        }
    }
}

/// Resolves a `@Scheduled` time zone identifier at container-freeze time.
///
/// Called only from macro-generated code. The macro rejects an identifier
/// Foundation does not know, so this fires only when the build machine's
/// time zone database and the deployment's disagree — a slim but real case,
/// and one that used to resolve silently to GMT and run the job at the wrong
/// hour. Failing at freeze puts it in the startup log instead.
public func _flightTimeZone(_ identifier: String, job: String) throws -> TimeZone {
    guard let zone = TimeZone(identifier: identifier) else {
        throw SchedulerStartupError.unknownTimeZone(job: job, identifier: identifier)
    }
    return zone
}
