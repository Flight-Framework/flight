import FlightCore
import Synchronization
import Foundation
import Testing

@testable import FlightScheduler

/// The macro's real output, exercised through a real container.
///
/// Macro fixture tests pin the generated text; this pins that the generated
/// text actually *works* — resolves the component, produces a registration,
/// and calls the method.
@Suite("Scheduler — registration")
struct SchedulerRegistrationTests {

    @Scheduler
    final class Jobs: Sendable {
        static let ran = Mutex<[String]>([])

        @Scheduled("0 0 3 * * *")
        func nightly() {
            Jobs.ran.withLock { $0.append("nightly") }
        }

        @Scheduled(every: .minutes(5), onEveryNode: true)
        func refresh() async throws {
            Jobs.ran.withLock { $0.append("refresh") }
        }
    }

    // No hand registration of `Jobs` itself: @Scheduler registers the
    // component as well as its jobs, exactly as @Controller does.
    private func freeze() throws -> Container {
        let container = Container()
        try Jobs._flightRegister(container)
        try container.freeze()
        return container
    }

    @Test("every @Scheduled method becomes a registration")
    func bothJobsRegister() throws {
        let jobs = try freeze().collectScheduledJobs()
        #expect(jobs.count == 2)
        // Names are fully qualified, so two schedulers may share a method name.
        #expect(jobs.allSatisfy { $0.name.contains("Jobs.") })
    }

    @Test("the default scope is once, and onEveryNode opts out of it")
    func scopes() throws {
        let jobs = try freeze().collectScheduledJobs()
        let nightly = try #require(jobs.first { $0.name.hasSuffix(".nightly") })
        let refresh = try #require(jobs.first { $0.name.hasSuffix(".refresh") })
        #expect(nightly.scope == .once, "a job that says nothing must run once")
        #expect(refresh.scope == .onEveryNode)
    }

    @Test("a cron job carries its parsed expression and time zone")
    func cronTrigger() throws {
        let jobs = try freeze().collectScheduledJobs()
        let nightly = try #require(jobs.first { $0.name.hasSuffix(".nightly") })
        guard case .cron(let expression, let zone) = nightly.trigger else {
            Issue.record("expected a cron trigger"); return
        }
        #expect(expression.description == "0 0 3 * * *")
        // Asserted by offset, not identifier: Foundation normalizes "UTC" to
        // the identifier "GMT" on Linux. Same zone, different label — and the
        // property that matters is that the default is *not* the machine's
        // local zone, so a deployment behaves the same everywhere.
        #expect(zone.secondsFromGMT() == 0, "the default must be UTC, not local")
    }

    @Test("an interval job carries its period")
    func intervalTrigger() throws {
        let jobs = try freeze().collectScheduledJobs()
        let refresh = try #require(jobs.first { $0.name.hasSuffix(".refresh") })
        guard case .interval(let period, _) = refresh.trigger else {
            Issue.record("expected an interval trigger"); return
        }
        #expect(period == .minutes(5))
    }

    @Test("running a registration calls the method")
    func runCallsTheMethod() async throws {
        Jobs.ran.withLock { $0.removeAll() }
        let jobs = try freeze().collectScheduledJobs()
        for job in jobs { try await job.run() }
        #expect(Jobs.ran.withLock { $0.sorted() } == ["nightly", "refresh"])
    }

    @Test("a hand-registered job collects alongside the macro's")
    func handRegistered() throws {
        let container = Container()
        try Jobs._flightRegister(container)
        container.registerScheduledJob("reconcile", cron: try CronExpression("0 */10 * * * *")) {}
        try container.freeze()
        #expect(try container.collectScheduledJobs().count == 3)
    }
}
