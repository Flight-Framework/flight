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
        let fired = Mutex<[Date]>([])
        let clock = TestSchedulerClock(now: epoch)
        let job = ScheduledJobRegistration(
            name: "daily",
            trigger: .cron(try CronExpression("0 0 3 * * *"), timeZone: .gmt),
            scope: .onEveryNode
        ) { [clock] in fired.withLock { $0.append(clock.now) } }

        let runner = JobRunner(
            job: job, coordinator: LocalJobCoordinator(), clock: clock, logger: quiet)

        // Let the loop run a few firings, then cancel it.
        let task = Task { await runner.run() }
        while fired.withLock({ $0.count }) < 3 { await Task.yield() }
        task.cancel()
        _ = await task.value

        let stamps = fired.withLock { $0 }
        #expect(stamps.count >= 3)
        // 03:00 UTC on three consecutive days, 24h apart.
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

    @Test("no coordinator registered means single-process mode")
    func modeWithoutCoordinator() throws {
        let container = Container()
        try container.freeze()
        let coordinator = SchedulerService.resolveCoordinator(in: container)
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
        let coordinator = SchedulerService.resolveCoordinator(in: container)
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
