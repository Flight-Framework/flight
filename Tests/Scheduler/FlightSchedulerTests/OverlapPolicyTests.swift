import Foundation
import Logging
import Synchronization
import Testing

import FlightSchedulerTesting

@testable import FlightScheduler

/// `OverlapPolicy` shipped as a no-op, and every test passed.
///
/// The tests all called `fire()` directly, so they proved the *decision*
/// while the production loop — which awaited `fire()` before computing the
/// next firing — could never present it with an overlap to decide about.
/// `isRunning` was therefore never true outside a test, `.skippedOverlap`
/// was unreachable, and `.queue`'s documented "waits for the running job,
/// then runs again" simply did not happen. That is the same shape as the
/// `@Scheduler`-shipped-inert incident in GAPS.md, so these tests drive the
/// real `run()` loop and never call `fire()` by hand.
@Suite("Scheduler — overlap, through the real loop")
struct OverlapPolicyTests {

    private let epoch = Date(timeIntervalSince1970: 1_800_000_000)
    private var quiet: Logger {
        var logger = Logger(label: "test")
        logger.logLevel = .critical
        return logger
    }

    /// A job body the test holds open, so a firing really can arrive while
    /// the previous run is still going.
    private actor Gate {
        private var isOpen = false
        private var waiting: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { waiting.append($0) }
        }

        func open() {
            isOpen = true
            for continuation in waiting { continuation.resume() }
            waiting = []
        }
    }

    @Test(".skip refuses a firing that lands on a running job")
    func skipIsReachable() async throws {
        let clock = TestSchedulerClock(now: epoch)
        let gate = Gate()
        let started = Mutex(0)
        let job = ScheduledJobRegistration(
            name: "slow",
            trigger: .cron(try CronExpression("0 * * * * *"), timeZone: .gmt),
            scope: .onEveryNode, overlap: .skip
        ) {
            started.withLock { $0 += 1 }
            await gate.wait()
        }
        let runner = JobRunner(
            job: job, coordinator: LocalJobCoordinator(), clock: clock, logger: quiet)

        let task = Task { await runner.run() }
        var sawSkip = false
        for _ in 0..<100_000 {
            if await runner.currentStatus().lastOutcome == .skippedOverlap {
                sawSkip = true
                break
            }
            await Task.yield()
        }
        // Read before releasing the gate: afterwards the held run finishes
        // and later firings are legitimately free to start.
        let startedWhileBusy = started.withLock { $0 }
        await gate.open()
        task.cancel()
        _ = await task.value

        #expect(sawSkip, ".skip never recorded a skipped firing")
        #expect(startedWhileBusy == 1, "a second copy of the job started while the first ran")
    }

    @Test(".queue runs the held firing afterwards, never alongside")
    func queueRunsAfterwards() async throws {
        let clock = TestSchedulerClock(now: epoch)
        let gate = Gate()
        let inFlight = Mutex(0)
        let peak = Mutex(0)
        let completed = Mutex(0)
        let job = ScheduledJobRegistration(
            name: "slow",
            trigger: .cron(try CronExpression("0 * * * * *"), timeZone: .gmt),
            scope: .onEveryNode, overlap: .queue
        ) {
            let now = inFlight.withLock { $0 += 1; return $0 }
            peak.withLock { $0 = max($0, now) }
            // Only the first run waits; the queued one must not deadlock
            // behind a gate the test has already opened.
            if completed.withLock({ $0 }) == 0 { await gate.wait() }
            inFlight.withLock { $0 -= 1 }
            completed.withLock { $0 += 1 }
        }
        let runner = JobRunner(
            job: job, coordinator: LocalJobCoordinator(), clock: clock, logger: quiet)

        let task = Task { await runner.run() }
        // Wait until the loop has actually parked a firing behind the run.
        var queued = false
        for _ in 0..<100_000 {
            if await runner.pendingFiring() != nil {
                queued = true
                break
            }
            await Task.yield()
        }
        await gate.open()
        for _ in 0..<100_000 where completed.withLock({ $0 }) < 2 { await Task.yield() }
        task.cancel()
        _ = await task.value

        #expect(queued, ".queue never held a firing — the policy is still a no-op")
        #expect(completed.withLock { $0 } >= 2, "the queued firing never ran")
        #expect(peak.withLock { $0 } == 1, ".queue ran two copies at once; it promises 'then'")
    }

    @Test("an interval job's firing can never overlap, so the policy is moot")
    func intervalNeverOverlaps() async throws {
        // Measured from the end of the previous run: the next firing is not
        // even known until this one finishes. Worth pinning, because it is
        // why the loop still awaits interval firings inline.
        let clock = TestSchedulerClock(now: epoch)
        let peak = Mutex(0)
        let inFlight = Mutex(0)
        let ran = Mutex(0)
        let job = ScheduledJobRegistration(
            name: "tick",
            trigger: .interval(.seconds(1), initialDelay: .seconds(0)),
            scope: .onEveryNode, overlap: .queue
        ) {
            let now = inFlight.withLock { $0 += 1; return $0 }
            peak.withLock { $0 = max($0, now) }
            await Task.yield()
            inFlight.withLock { $0 -= 1 }
            ran.withLock { $0 += 1 }
        }
        let runner = JobRunner(
            job: job, coordinator: LocalJobCoordinator(), clock: clock, logger: quiet)
        let task = Task { await runner.run() }
        for _ in 0..<100_000 where ran.withLock({ $0 }) < 3 { await Task.yield() }
        task.cancel()
        _ = await task.value

        #expect(ran.withLock { $0 } >= 3)
        #expect(peak.withLock { $0 } == 1)
    }
}
