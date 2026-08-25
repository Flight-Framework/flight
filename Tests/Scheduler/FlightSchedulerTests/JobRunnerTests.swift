import Foundation
import Logging
import Synchronization
import Testing

@testable import FlightScheduler

/// The runtime's decision logic: who runs a firing, and what happens when
/// things go wrong. Driven by a virtual clock, so nothing here sleeps.
@Suite("Scheduler — running jobs")
struct JobRunnerTests {

    private let epoch = Date(timeIntervalSince1970: 1_800_000_000)
    private var quiet: Logger {
        var logger = Logger(label: "test")
        logger.logLevel = .critical
        return logger
    }

    private func job(
        _ name: String = "job",
        scope: JobScope = .once,
        overlap: OverlapPolicy = .skip,
        run: @escaping @Sendable () async throws -> Void
    ) -> ScheduledJobRegistration {
        ScheduledJobRegistration(
            name: name,
            trigger: .cron(try! CronExpression("0 0 3 * * *"), timeZone: .gmt),
            scope: scope, overlap: overlap, run: run)
    }

    @Test("a claimed firing runs the job and releases afterwards")
    func claimedRuns() async {
        let ran = Mutex(0)
        let coordinator = StubCoordinator(claims: true)
        let runner = JobRunner(
            job: job { ran.withLock { $0 += 1 } },
            coordinator: coordinator, clock: TestClock(now: epoch), logger: quiet)

        await runner.fire(scheduledFor: epoch)

        #expect(ran.withLock { $0 } == 1)
        #expect(coordinator.claims.withLock { $0 } == ["job"])
        #expect(coordinator.releases.withLock { $0 } == ["job"], "a claim must be released")
        #expect(await runner.currentStatus().lastOutcome == .succeeded)
    }

    @Test("an unclaimed firing does not run — the whole point of .once")
    func unclaimedDoesNotRun() async {
        let ran = Mutex(0)
        let runner = JobRunner(
            job: job { ran.withLock { $0 += 1 } },
            coordinator: StubCoordinator(claims: false),
            clock: TestClock(now: epoch), logger: quiet)

        await runner.fire(scheduledFor: epoch)

        #expect(ran.withLock { $0 } == 0)
        #expect(await runner.currentStatus().lastOutcome == .notClaimed)
    }

    @Test("an onEveryNode job never consults the coordinator")
    func everyNodeSkipsCoordination() async {
        let ran = Mutex(0)
        let coordinator = StubCoordinator(claims: false)  // would refuse, if asked
        let runner = JobRunner(
            job: job(scope: .onEveryNode) { ran.withLock { $0 += 1 } },
            coordinator: coordinator, clock: TestClock(now: epoch), logger: quiet)

        await runner.fire(scheduledFor: epoch)

        #expect(ran.withLock { $0 } == 1)
        #expect(coordinator.claims.withLock { $0 }.isEmpty)
    }

    @Test("a coordinator that cannot answer skips rather than assuming yes")
    func coordinatorFailureSkips() async {
        // Skipping a firing is recoverable. Running a once-only job on every
        // server because the lock service blipped is not.
        let ran = Mutex(0)
        let runner = JobRunner(
            job: job { ran.withLock { $0 += 1 } },
            coordinator: StubCoordinator(failsWith: StubError(message: "down")),
            clock: TestClock(now: epoch), logger: quiet)

        await runner.fire(scheduledFor: epoch)

        #expect(ran.withLock { $0 } == 0, "must not run when coordination is unknown")
        let status = await runner.currentStatus()
        #expect(status.failureCount == 1)
        if case .failed(let message) = status.lastOutcome {
            #expect(message.contains("coordinator"))
        } else {
            Issue.record("expected a failure outcome, got \(String(describing: status.lastOutcome))")
        }
    }

    @Test("a throwing job is recorded and does not propagate")
    func failingJobIsContained() async {
        // One broken job must not stop the scheduler or its siblings.
        let runner = JobRunner(
            job: job { throw StubError(message: "boom") },
            coordinator: StubCoordinator(), clock: TestClock(now: epoch), logger: quiet)

        await runner.fire(scheduledFor: epoch)

        let status = await runner.currentStatus()
        #expect(status.failureCount == 1)
        #expect(status.runCount == 0)
        if case .failed(let message) = status.lastOutcome {
            #expect(message.contains("boom"))
        } else {
            Issue.record("expected a failure outcome")
        }
    }

    @Test("a failed run still releases its claim")
    func failureStillReleases() async {
        // Otherwise a job that throws would hold its lock and never run again.
        let coordinator = StubCoordinator()
        let runner = JobRunner(
            job: job { throw StubError(message: "boom") },
            coordinator: coordinator, clock: TestClock(now: epoch), logger: quiet)

        await runner.fire(scheduledFor: epoch)

        #expect(coordinator.releases.withLock { $0 } == ["job"])
    }

    @Test("status accumulates across firings")
    func statusAccumulates() async {
        let shouldThrow = Mutex(false)
        let runner = JobRunner(
            job: job {
                if shouldThrow.withLock({ $0 }) { throw StubError(message: "x") }
            },
            coordinator: StubCoordinator(), clock: TestClock(now: epoch), logger: quiet)

        await runner.fire(scheduledFor: epoch)
        shouldThrow.withLock { $0 = true }
        await runner.fire(scheduledFor: epoch.addingTimeInterval(60))

        let status = await runner.currentStatus()
        #expect(status.runCount == 1)
        #expect(status.failureCount == 1)
        #expect(status.lastFired == epoch.addingTimeInterval(60))
    }
}
