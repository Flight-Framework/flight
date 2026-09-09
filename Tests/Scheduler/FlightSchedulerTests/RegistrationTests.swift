import FlightCore
import Synchronization
import Foundation
import Testing

@testable import FlightScheduler

/// The macro's real output, exercised as values.
///
/// Macro fixture tests pin the generated text; this pins that the generated
/// text actually *works* — builds the component, produces registrations, and
/// calls the method.
@Suite("Scheduler — registration")
struct SchedulerRegistrationTests {

    @Scheduler
    struct Jobs: Sendable {
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

    /// The jobs as values — what the composition root's `flightScheduledJobs`
    /// collects. `@Scheduler` emits one factory returning them all, built from
    /// a component the caller supplies.
    private func scheduledJobs() -> [ScheduledJobRegistration] {
        Jobs._flightScheduledJobs { Jobs() }
    }

    @Test("every @Scheduled method becomes a registration")
    func bothJobsRegister() throws {
        let jobs = scheduledJobs()
        #expect(jobs.count == 2)
        // Names are fully qualified, so two schedulers may share a method name.
        #expect(jobs.allSatisfy { $0.name.contains("Jobs.") })
    }

    @Test("the default scope is once, and onEveryNode opts out of it")
    func scopes() throws {
        let jobs = scheduledJobs()
        let nightly = try #require(jobs.first { $0.name.hasSuffix(".nightly") })
        let refresh = try #require(jobs.first { $0.name.hasSuffix(".refresh") })
        #expect(nightly.scope == .once, "a job that says nothing must run once")
        #expect(refresh.scope == .onEveryNode)
    }

    @Test("a cron job carries its parsed expression and time zone")
    func cronTrigger() throws {
        let jobs = scheduledJobs()
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
        let jobs = scheduledJobs()
        let refresh = try #require(jobs.first { $0.name.hasSuffix(".refresh") })
        guard case .interval(let period, _) = refresh.trigger else {
            Issue.record("expected an interval trigger"); return
        }
        #expect(period == .minutes(5))
    }

    @Test("running a registration calls the method")
    func runCallsTheMethod() async throws {
        Jobs.ran.withLock { $0.removeAll() }
        let jobs = scheduledJobs()
        for job in jobs { try await job.run() }
        #expect(Jobs.ran.withLock { $0.sorted() } == ["nightly", "refresh"])
    }

    @Test("a hand-declared job collects alongside the macro's")
    func handRegistered() throws {
        // A job declared as a plain value, the way a module contributes one
        // that isn't attached to a `@Scheduler` type.
        var all = scheduledJobs()
        all.append(
            ScheduledJobRegistration(
                name: "reconcile",
                trigger: .cron(try CronExpression("0 */10 * * * *"), timeZone: TimeZone(identifier: "UTC")!)
            ) {})
        #expect(all.count == 3)
    }
}
