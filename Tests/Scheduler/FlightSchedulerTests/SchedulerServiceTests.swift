import FlightCore
import Foundation
import Logging
import Synchronization
import Testing

import FlightSchedulerTesting

@testable import FlightScheduler

@Suite("Scheduler — the loop and the service")
struct SchedulerServiceTests {

    private let epoch = Date(timeIntervalSince1970: 1_800_000_000)
    private var quiet: Logger {
        var logger = Logger(label: "test")
        logger.logLevel = .critical
        return logger
    }

    @Test("the loop fires on schedule, in order, without sleeping for real")
    func loopFiresOnSchedule() async throws {
        let fired = Mutex(0)
        let clock = TestSchedulerClock(now: epoch)
        let job = ScheduledJobRegistration(
            name: "daily",
            trigger: .cron(try CronExpression("0 0 3 * * *"), timeZone: .gmt),
            scope: .onEveryNode
        ) { fired.withLock { $0 += 1 } }

        let runner = JobRunner(
            job: job, coordinator: LocalJobCoordinator(), clock: clock, logger: quiet)

        // Let the loop run a few firings, then cancel it.
        let task = Task { await runner.run() }
        for _ in 0..<100_000 where fired.withLock({ $0 }) < 3 { await Task.yield() }
        task.cancel()
        _ = await task.value

        #expect(fired.withLock { $0 } >= 3)
        // The firing sequence is what the loop slept to, not what the job
        // body read off the clock: a cron firing runs in its own task now —
        // that is what makes `OverlapPolicy` reachable — so with a clock that
        // jumps rather than waits, the loop is already at the next instant by
        // the time the body runs. 03:00 UTC on consecutive days, 24h apart.
        let stamps = clock.sleeps
        #expect(stamps.count >= 3)
        for (a, b) in zip(stamps, stamps.dropFirst()) {
            #expect(b.timeIntervalSince(a) == 86_400)
        }
    }

    @Test("a schedule with no future firing stops instead of spinning")
    func impossibleScheduleStops() async throws {
        // 30 February. The loop must return, not burn a core forever.
        let clock = TestSchedulerClock(now: epoch)
        let job = ScheduledJobRegistration(
            name: "never",
            trigger: .cron(try CronExpression("0 0 0 30 2 *"), timeZone: .gmt),
            scope: .onEveryNode
        ) {}
        let runner = JobRunner(
            job: job, coordinator: LocalJobCoordinator(), clock: clock, logger: quiet)

        // Completes on its own, with no cancellation.
        await runner.run()
        #expect(clock.sleeps.isEmpty, "it should never have slept")
    }

    @Test("an interval job measures from the end of the previous run")
    func intervalFromCompletion() async throws {
        let clock = TestSchedulerClock(now: epoch)
        let fired = Mutex<[Date]>([])
        let job = ScheduledJobRegistration(
            name: "every-minute",
            trigger: .interval(.minutes(1), initialDelay: .seconds(0)),
            scope: .onEveryNode
        ) { [clock] in fired.withLock { $0.append(clock.now) } }

        let runner = JobRunner(
            job: job, coordinator: LocalJobCoordinator(), clock: clock, logger: quiet)
        let task = Task { await runner.run() }
        while fired.withLock({ $0.count }) < 3 { await Task.yield() }
        task.cancel()
        _ = await task.value

        let stamps = fired.withLock { $0 }
        for (a, b) in zip(stamps, stamps.dropFirst()) {
            #expect(b.timeIntervalSince(a) == 60)
        }
    }

    @Test("one exhausted schedule does not stop the other jobs")
    func exhaustedScheduleDoesNotStopSiblings() async throws {
        // 30 February parses fine and has no future firing, so its runner
        // returns on its own — which is that job stopping, and nothing more.
        // `await group.next()` took the first child to finish as the signal
        // to cancel everything, so one impossible schedule silently killed
        // every other job in the process. Docs/scheduler.md promises the
        // opposite in as many words: "one broken job never stops the others".
        let clock = TestSchedulerClock(now: epoch)
        let fired = Mutex(0)
        let container = Container()
        container.registerScheduledJob(
            "never", cron: try CronExpression("0 0 0 30 2 *"), scope: .onEveryNode) {}
        container.registerScheduledJob(
            "daily", cron: try CronExpression("0 0 3 * * *"), scope: .onEveryNode
        ) { fired.withLock { $0 += 1 } }
        try container.freeze()

        let service = SchedulerService(container: container, clock: clock, logger: quiet)
        let stopped = Mutex(false)
        let task = Task {
            try await service.run()
            stopped.withLock { $0 = true }
        }
        // Bounded, so a regression is a failed expectation rather than a hang.
        for _ in 0..<100_000 where fired.withLock({ $0 }) < 3 { await Task.yield() }
        let firedSoFar = fired.withLock { $0 }
        // Ample opportunity for a premature group cancellation to land — the
        // buggy version fires a few times before cancellation propagates, so
        // counting firings alone would not catch it.
        for _ in 0..<10_000 { await Task.yield() }

        #expect(
            !stopped.withLock { $0 },
            "the service returned when the impossible job's runner ended")
        #expect(
            fired.withLock { $0 } > firedSoFar,
            "the surviving job stopped firing when its impossible sibling ended")

        task.cancel()
        _ = try? await task.value
        for _ in 0..<10_000 where !stopped.withLock({ $0 }) { await Task.yield() }
        #expect(stopped.withLock { $0 }, "shutdown must still stop the scheduler")
    }

    @Test("a coordinator that fails to resolve is a wiring bug, not single-process mode")
    func brokenCoordinatorIsNotSilentDegradation() throws {
        // The comment above resolveCoordinator said a non-.notRegistered
        // failure "is a real wiring bug and should not be swallowed" while
        // every path returned LocalJobCoordinator, so a misconfigured
        // distributed coordinator quietly degraded a cluster to running
        // every once-job on every node — the exact outcome a coordinator
        // exists to prevent.
        let container = Container()
        container.register((any JobCoordinator).self, scope: .scoped) { _ in
            StubJobCoordinator.claiming
        }
        try container.freeze()
        #expect(throws: ResolutionError.self) {
            try SchedulerService.resolveCoordinator(in: container)
        }
    }

    @Test("no coordinator registered means single-process mode")
    func modeWithoutCoordinator() throws {
        let container = Container()
        try container.freeze()
        let coordinator = try SchedulerService.resolveCoordinator(in: container)
        #expect(coordinator is LocalJobCoordinator)
        #expect(SchedulerService.mode(for: coordinator) == .singleProcess)
    }

    @Test("a registered coordinator is found and named in the mode")
    func modeWithCoordinator() throws {
        let container = Container()
        container.register((any JobCoordinator).self, scope: .singleton) { _ in
            StubJobCoordinator.claiming
        }
        try container.freeze()
        let coordinator = try SchedulerService.resolveCoordinator(in: container)
        #expect(!(coordinator is LocalJobCoordinator))
        #expect(SchedulerService.mode(for: coordinator) == .coordinated("stub"))
    }
}

@Suite("Scheduler — observable status")
struct SchedulerStatusTests {
    private let epoch = Date(timeIntervalSince1970: 1_800_000_000)
    private var quiet: Logger {
        var l = Logger(label: "test"); l.logLevel = .critical; return l
    }

    @Test("a firing is visible in the shared status")
    func firingIsVisible() async throws {
        let status = SchedulerStatus()
        let job = ScheduledJobRegistration(
            name: "report",
            trigger: .cron(try CronExpression("0 0 3 * * *"), timeZone: .gmt),
            scope: .onEveryNode) {}
        let runner = JobRunner(
            job: job, coordinator: LocalJobCoordinator(),
            clock: TestSchedulerClock(now: epoch), logger: quiet, status: status)

        #expect(status.snapshot().isEmpty)
        await runner.fire(scheduledFor: epoch)

        let seen = try #require(status.status(of: "report"))
        #expect(seen.lastOutcome == .succeeded)
        #expect(seen.runCount == 1)
    }

    @Test("a failure is visible too — the reason to look at all")
    func failureIsVisible() async throws {
        let status = SchedulerStatus()
        let job = ScheduledJobRegistration(
            name: "flaky",
            trigger: .cron(try CronExpression("0 0 3 * * *"), timeZone: .gmt),
            scope: .onEveryNode) { throw StubError(message: "nope") }
        let runner = JobRunner(
            job: job, coordinator: LocalJobCoordinator(),
            clock: TestSchedulerClock(now: epoch), logger: quiet, status: status)

        await runner.fire(scheduledFor: epoch)

        let seen = try #require(status.status(of: "flaky"))
        #expect(seen.failureCount == 1)
        if case .failed(let message) = seen.lastOutcome {
            #expect(message.contains("nope"))
        } else { Issue.record("expected a failure") }
    }

    @Test("the snapshot is sorted, so a status page does not reshuffle")
    func snapshotIsStable() async throws {
        let status = SchedulerStatus()
        for name in ["zeta", "alpha", "middle"] {
            let job = ScheduledJobRegistration(
                name: name,
                trigger: .cron(try CronExpression("0 0 3 * * *"), timeZone: .gmt),
                scope: .onEveryNode) {}
            await JobRunner(
                job: job, coordinator: LocalJobCoordinator(),
                clock: TestSchedulerClock(now: epoch), logger: quiet, status: status
            ).fire(scheduledFor: epoch)
        }
        #expect(status.snapshot().map(\.name) == ["alpha", "middle", "zeta"])
    }
}
