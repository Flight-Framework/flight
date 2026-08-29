import FlightCore
import Foundation

/// When a job's schedule is expressed as a fixed interval rather than a
/// calendar expression.
public enum JobTrigger: Sendable, Equatable {
    /// A cron expression, evaluated in a time zone.
    case cron(CronExpression, timeZone: TimeZone)
    /// A fixed period between runs, measured from the end of the previous run.
    ///
    /// From the *end*, not the start: a job that takes longer than its period
    /// would otherwise be perpetually late and eventually overlapping, and
    /// "every five minutes" almost always means "with five minutes of quiet
    /// in between".
    case interval(Duration, initialDelay: Duration)

    /// The next time this trigger fires after `date`, or nil when a cron
    /// expression can never match again.
    public func nextFireDate(after date: Date, lastCompletion: Date?) -> Date? {
        switch self {
        case .cron(let expression, let timeZone):
            return expression.nextFireDate(after: date, in: timeZone)
        case .interval(let period, let initialDelay):
            // Whole seconds only used to be read off both durations, so
            // `.milliseconds(500)` became a zero-length period — a firing
            // every time round the loop with no sleep in between — and
            // `.milliseconds(1500)` fired every second.
            let seconds = period.flightSeconds
            let base = lastCompletion ?? date.addingTimeInterval(
                initialDelay.flightSeconds - seconds)
            return base.addingTimeInterval(seconds)
        }
    }

    /// The period, for an interval trigger — nil for cron.
    public var intervalPeriod: Duration? {
        switch self {
        case .cron: nil
        case .interval(let period, _): period
        }
    }

    /// Whether this trigger's firing instants are this node's own.
    ///
    /// An interval is measured from the end of the previous run, so two nodes
    /// that started at different moments never agree on when a firing is —
    /// which means a ``JobCoordinator`` has no shared key to arbitrate and
    /// ``JobScope/once`` cannot be honoured. Cron instants are wall-clock and
    /// identical everywhere.
    public var isNodeLocal: Bool {
        switch self {
        case .cron: false
        case .interval: true
        }
    }
}

/// Whether a job runs once across the deployment, or once on every node.
///
/// Deliberately not spelled in cluster vocabulary. On a single server the
/// two are the same thing, and making someone with one machine reason about
/// "cluster" versus "node" to schedule a nightly report is a bad trade. The
/// default is ``once`` — which reads correctly whether there is one server or
/// five, and is the safe answer either way: a report that runs twice is a
/// bug, a report that runs once never is.
public enum JobScope: Sendable, Equatable {
    /// Runs a single time per firing, however many servers are running.
    ///
    /// On one server that is simply "it runs". On several it requires a
    /// ``JobCoordinator``; without one registered the scheduler says so
    /// loudly at startup rather than quietly running the job everywhere.
    case once
    /// Runs on every server, every firing. For work that is per-process by
    /// nature: refreshing an in-memory cache, trimming a local buffer.
    case onEveryNode
}

/// What to do when a firing arrives and the previous run has not finished.
///
/// Only a cron schedule can present this choice. An interval is measured from
/// the end of the previous run, so its next firing is not even known until
/// the current one finishes — overlap there is impossible by construction,
/// and the policy is ignored.
public enum OverlapPolicy: Sendable, Equatable {
    /// Skip the firing entirely and log it. The default: a job still running
    /// when its next firing arrives is usually a job that got slower, and
    /// piling a second copy onto the first is how a slow job becomes an
    /// outage.
    case skip
    /// Wait for the running job, then run again immediately.
    ///
    /// Then, never alongside: two copies at once is what ``skip`` exists to
    /// avoid, and this differs from it in *when*, not in how many. At most
    /// one firing waits — a job so far behind that a second one arrives is
    /// already in trouble, and an unbounded backlog of copies is the same
    /// outage by a slower route — so a newly arrived firing displaces the
    /// waiting one, and the displacement is logged.
    case queue
}

/// One registered scheduled job: its schedule, how it should run, and the
/// work itself.
///
/// Produced by the `@Scheduler` macro from a `@Scheduled` method, and
/// gathered post-freeze by ``FlightCore/Container/collectScheduledJobs()``.
/// Registered through the same container as everything else — scheduling is
/// not a separate system from dependency injection.
public struct ScheduledJobRegistration: Sendable {
    /// `MyJobs.nightlyRollup` — what logs, diagnostics and the actuator show.
    public let name: String
    public let trigger: JobTrigger
    public let scope: JobScope
    public let overlap: OverlapPolicy
    /// Resolves the component and calls the method. Throwing is expected and
    /// handled: a failing job is logged and retried at its next firing, not
    /// propagated into the scheduler loop.
    public let run: @Sendable () async throws -> Void

    public init(
        name: String,
        trigger: JobTrigger,
        scope: JobScope = .once,
        overlap: OverlapPolicy = .skip,
        run: @escaping @Sendable () async throws -> Void
    ) {
        self.name = name
        self.trigger = trigger
        self.scope = scope
        self.overlap = overlap
        self.run = run
    }
}

extension Container {
    /// Every registered scheduled job, in registration order (post-freeze).
    public func collectScheduledJobs() throws -> [ScheduledJobRegistration] {
        // Core's public `allRegistrations()` carries (typeName, qualifier),
        // which is exactly enough to enumerate one type's registrations
        // without new Core API.
        //
        // This is the second copy of these five lines — FlightWeb has the
        // same helper, privately, for routes and middleware. A third
        // consumer is the point at which it should be promoted into Core
        // rather than copied again.
        let typeName = String(reflecting: ScheduledJobRegistration.self)
        return try allRegistrations()
            .filter { $0.typeName == typeName }
            .map { try resolve(ScheduledJobRegistration.self, qualifier: $0.qualifier) }
    }

    /// Registers a scheduled job by hand — the escape hatch beside the
    /// `@Scheduled` macro, for a schedule that is only known at startup.
    ///
    /// ```swift
    /// container.registerScheduledJob(
    ///     "reconcile", cron: try CronExpression("0 */10 * * * *")
    /// ) { try await reconciler.run() }
    /// ```
    public func registerScheduledJob(
        _ name: String,
        cron expression: CronExpression,
        timeZone: TimeZone = TimeZone(identifier: "UTC")!,
        scope: JobScope = .once,
        overlap: OverlapPolicy = .skip,
        _ run: @escaping @Sendable () async throws -> Void
    ) {
        register(ScheduledJobRegistration.self, qualifier: name, scope: .singleton) { _ in
            ScheduledJobRegistration(
                name: name,
                trigger: .cron(expression, timeZone: timeZone),
                scope: scope, overlap: overlap, run: run)
        }
    }

    /// Fixed-interval counterpart to ``registerScheduledJob(_:cron:timeZone:scope:overlap:_:)``.
    public func registerScheduledJob(
        _ name: String,
        every period: Duration,
        initialDelay: Duration = .seconds(0),
        scope: JobScope = .once,
        overlap: OverlapPolicy = .skip,
        _ run: @escaping @Sendable () async throws -> Void
    ) {
        register(ScheduledJobRegistration.self, qualifier: name, scope: .singleton) { _ in
            ScheduledJobRegistration(
                name: name,
                trigger: .interval(period, initialDelay: initialDelay),
                scope: scope, overlap: overlap, run: run)
        }
    }
}
