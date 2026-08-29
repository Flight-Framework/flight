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
    private let status_: SchedulerStatus?

    private var status: JobStatus
    private var isRunning = false
    private var lastCompletion: Date?
    /// A firing held back by ``OverlapPolicy/queue`` while a run is going.
    ///
    /// At most one. `.queue` promises "wait for the running job, then run
    /// again immediately" — singular — and an unbounded backlog would turn a
    /// job that has grown slow into a growing queue of copies, which is the
    /// outage `.skip`'s doc comment describes. A firing arriving while one is
    /// already waiting replaces it and is logged.
    private var pending: Date?

    init(
        job: ScheduledJobRegistration,
        coordinator: any JobCoordinator,
        clock: any SchedulerClock,
        logger: Logger,
        status: SchedulerStatus? = nil
    ) {
        self.job = job
        self.coordinator = coordinator
        self.clock = clock
        self.logger = logger
        self.status_ = status
        self.status = JobStatus(
            name: job.name, lastFired: nil, lastOutcome: nil, lastDuration: nil,
            nextFire: nil, runCount: 0, failureCount: 0)
    }

    func currentStatus() -> JobStatus { status }

    /// Mirrors the local status into the shared holder, so `/jobs` and the
    /// like see it without reaching into the actor on every request.
    private func publish() { status_?.record(status) }

    /// The firing currently held by ``OverlapPolicy/queue``, for tests.
    func pendingFiring() -> Date? { pending }

    /// The scheduling loop. Returns when the task is cancelled.
    func run() async {
        await withTaskGroup(of: Void.self) { group in
            while !Task.isCancelled {
                guard let next = job.trigger.nextFireDate(
                    after: clock.now, lastCompletion: lastCompletion)
                else {
                    // A cron expression that can never match again — 30
                    // February, or a date-bounded schedule that has passed.
                    // Say so once and stop, rather than spinning forever on a
                    // question with no answer. Only this job stops;
                    // `SchedulerService` deliberately does not read a runner
                    // finishing as the scheduler finishing.
                    logger.warning(
                        "scheduled job has no future firing; it will not run again",
                        metadata: ["job": .string(job.name)])
                    break
                }
                status.nextFire = next
                publish()

                do {
                    try await clock.sleep(until: next)
                } catch {
                    break  // cancelled
                }
                if Task.isCancelled { break }

                switch job.trigger {
                case .interval:
                    // An interval is measured from the end of the previous
                    // run, so the loop cannot compute the next firing until
                    // this one is done. Overlap is structurally impossible
                    // here, and awaiting inline is what makes it so.
                    await fire(scheduledFor: next)
                case .cron:
                    // Cron instants are absolute, so the next one is known
                    // now and the loop must go back to waiting for it rather
                    // than for the job. Awaiting the run here is what made
                    // `OverlapPolicy` unreachable: `isRunning` could never be
                    // true when `fire` was entered, so `.skip` never skipped
                    // and `.queue` never queued.
                    group.addTask { await self.fire(scheduledFor: next) }
                }
            }
            // Cancellation reaches the children through the group; waiting
            // keeps a run from being abandoned mid-flight on a clean stop.
            await group.waitForAll()
        }
    }

    /// One firing: the overlap decision, then the work.
    func fire(scheduledFor: Date) async {
        if isRunning {
            switch job.overlap {
            case .skip:
                status.lastFired = scheduledFor
                status.lastOutcome = .skippedOverlap
                logger.warning(
                    "scheduled job skipped: the previous run has not finished",
                    metadata: ["job": .string(job.name)])
                publish()
                return
            case .queue:
                if let displaced = pending {
                    logger.warning(
                        """
                        scheduled job is more than one firing behind; the older waiting \
                        firing was dropped
                        """,
                        metadata: [
                            "job": .string(job.name),
                            "dropped": .string("\(displaced)"),
                        ])
                }
                pending = scheduledFor
                return
            }
        }

        await execute(scheduledFor: scheduledFor)

        // Anything `.queue` held while that ran, one at a time — a queued
        // firing that itself overruns queues the next in turn.
        while let next = pending {
            pending = nil
            await execute(scheduledFor: next)
        }
    }

    /// The work of one firing, past the overlap decision.
    private func execute(scheduledFor: Date) async {
        // Set before the first suspension point, so a firing that arrives
        // while the coordinator is being consulted still sees a run in
        // progress. Claiming is part of the run.
        isRunning = true
        defer {
            isRunning = false
            // Every path, not just a completed run: an interval job whose
            // firing was refused by the coordinator would otherwise leave
            // `lastCompletion` unset and recompute the same past instant
            // forever, spinning instead of waiting out its period.
            lastCompletion = clock.now
        }

        if job.scope == .once {
            do {
                guard try await coordinator.claim(job: job.name, scheduledFor: scheduledFor) else {
                    status.lastFired = scheduledFor
                    status.lastOutcome = .notClaimed
                    logger.debug(
                        "scheduled job claimed by another process",
                        metadata: ["job": .string(job.name)])
                    publish()
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
                publish()
                return
            }
        }

        status.lastFired = scheduledFor
        let started = clock.now

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
        // Not truncated to whole seconds: a sub-second job reporting 0s is
        // the one number `/actuator/scheduled` exists to show.
        status.lastDuration = .seconds(clock.now.timeIntervalSince(started))
        publish()

        if job.scope == .once {
            await coordinator.release(job: job.name, scheduledFor: scheduledFor)
        }
    }
}
