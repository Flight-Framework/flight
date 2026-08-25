import Foundation
import Logging

/// What happened to one firing — the unit the actuator and the tests both
/// read.
public enum JobOutcome: Sendable, Equatable {
    case succeeded
    /// Another process claimed this firing.
    case notClaimed
    /// The previous run was still going and the policy is ``OverlapPolicy/skip``.
    case skippedOverlap
    /// The job threw. The message rather than the error, because this is
    /// stored for display and errors are not `Equatable`.
    case failed(String)
}

/// A job's history, kept small on purpose: enough for `/actuator/scheduled`
/// to answer "is this thing running and did it work", not a metrics system.
public struct JobStatus: Sendable, Equatable {
    public let name: String
    public var lastFired: Date?
    public var lastOutcome: JobOutcome?
    public var lastDuration: Duration?
    public var nextFire: Date?
    public var runCount: Int
    public var failureCount: Int
}

/// Runs one job's schedule: sleep until the next firing, decide whether this
/// process should run it, run it, repeat.
///
/// One of these per job, each its own task, so a slow job delays only itself.
/// A single loop over all jobs would make the slowest job the scheduler's
/// resolution, which is the classic way a scheduler quietly stops being one.
actor JobRunner {
    private let job: ScheduledJobRegistration
    private let coordinator: any JobCoordinator
    private let clock: any SchedulerClock
    private let logger: Logger

    private var status: JobStatus
    private var isRunning = false
    private var lastCompletion: Date?

    init(
        job: ScheduledJobRegistration,
        coordinator: any JobCoordinator,
        clock: any SchedulerClock,
        logger: Logger
    ) {
        self.job = job
        self.coordinator = coordinator
        self.clock = clock
        self.logger = logger
        self.status = JobStatus(
            name: job.name, lastFired: nil, lastOutcome: nil, lastDuration: nil,
            nextFire: nil, runCount: 0, failureCount: 0)
    }

    func currentStatus() -> JobStatus { status }

    /// The scheduling loop. Returns when the task is cancelled.
    func run() async {
        while !Task.isCancelled {
            guard let next = job.trigger.nextFireDate(
                after: clock.now, lastCompletion: lastCompletion)
            else {
                // A cron expression that can never match again — 30 February,
                // or a date-bounded schedule that has passed. Say so once and
                // stop, rather than spinning forever on a question with no
                // answer.
                logger.warning(
                    "scheduled job has no future firing; it will not run again",
                    metadata: ["job": .string(job.name)])
                return
            }
            status.nextFire = next

            do {
                try await clock.sleep(until: next)
            } catch {
                return  // cancelled
            }
            if Task.isCancelled { return }

            await fire(scheduledFor: next)
        }
    }

    /// One firing, exposed for tests so the decision logic can be exercised
    /// without the loop.
    func fire(scheduledFor: Date) async {
        if isRunning {
            switch job.overlap {
            case .skip:
                status.lastFired = scheduledFor
                status.lastOutcome = .skippedOverlap
                logger.warning(
                    "scheduled job skipped: the previous run has not finished",
                    metadata: ["job": .string(job.name)])
                return
            case .queue:
                // The caller is this job's own serial loop, so "queue" is
                // simply proceeding: the actor guarantees the previous run
                // completed before this one is entered.
                break
            }
        }

        if job.scope == .once {
            do {
                guard try await coordinator.claim(job: job.name, scheduledFor: scheduledFor) else {
                    status.lastFired = scheduledFor
                    status.lastOutcome = .notClaimed
                    logger.debug(
                        "scheduled job claimed by another process",
                        metadata: ["job": .string(job.name)])
                    return
                }
            } catch {
                // A coordinator that cannot answer must not be read as "yes".
                // Skipping a firing is recoverable; running a once-only job
                // everywhere is not.
                status.lastFired = scheduledFor
                status.lastOutcome = .failed("coordinator unavailable: \(error)")
                status.failureCount += 1
                logger.error(
                    "scheduled job skipped: the coordinator could not be reached",
                    metadata: ["job": .string(job.name), "error": .string("\(error)")])
                return
            }
        }

        isRunning = true
        status.lastFired = scheduledFor
        let started = clock.now
        defer {
            isRunning = false
            lastCompletion = clock.now
        }

        do {
            try await job.run()
            status.lastOutcome = .succeeded
            status.runCount += 1
        } catch {
            // A failing job is logged and tried again at its next firing.
            // Propagating would take down the scheduler, and one broken job
            // must not stop the others.
            status.lastOutcome = .failed("\(error)")
            status.failureCount += 1
            logger.error(
                "scheduled job failed",
                metadata: ["job": .string(job.name), "error": .string("\(error)")])
        }
        status.lastDuration = .seconds(Int(clock.now.timeIntervalSince(started)))

        if job.scope == .once {
            await coordinator.release(job: job.name, scheduledFor: scheduledFor)
        }
    }
}
