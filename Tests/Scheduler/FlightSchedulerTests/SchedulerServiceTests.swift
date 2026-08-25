import FlightCore
import Foundation
import Logging
import Synchronization
import Testing

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
        let clock = TestClock(now: epoch)
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
        let clock = TestClock(now: epoch)
        let job = ScheduledJobRegistration(
            name: "never",
            trigger: .cron(try CronExpression("0 0 0 30 2 *"), timeZone: .gmt),
            scope: .onEveryNode
        ) {}
        let runner = JobRunner(
            job: job, coordinator: LocalJobCoordinator(), clock: clock, logger: quiet)

        // Completes on its own, with no cancellation.
        await runner.run()
        #expect(clock.sleeps.withLock { $0 }.isEmpty, "it should never have slept")
    }

    @Test("an interval job measures from the end of the previous run")
    func intervalFromCompletion() async throws {
        let clock = TestClock(now: epoch)
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
            StubCoordinator()
        }
        try container.freeze()
        let coordinator = SchedulerService.resolveCoordinator(in: container)
        #expect(!(coordinator is LocalJobCoordinator))
        #expect(SchedulerService.mode(for: coordinator) == .coordinated("stub"))
    }
}
