import FlightCore
import Foundation

/// Marks a type whose `@Scheduled` methods should run on a schedule.
///
/// A `@Scheduler` type is an ordinary singleton component — inject what it
/// needs with `@Autowired`, exactly as anywhere else:
///
/// ```swift
/// @Scheduler
/// final class ReportJobs: Sendable {
///     @Autowired var reports: ReportService
///
///     @Scheduled("0 0 3 * * *")
///     func nightlyRollup() async throws {
///         try await reports.rollUpYesterday()
///     }
/// }
/// ```
///
/// Nothing registers this by hand: the build plugin finds the type, and this
/// macro registers one job per `@Scheduled` method into the same container
/// every other component goes through.
@attached(member, names: named(_flightRegister))
@attached(extension, conformances: _FlightRegistrable)
public macro Scheduler() =
    #externalMacro(module: "FlightSchedulerMacrosImpl", type: "SchedulerMacro")

/// Runs a method on a cron schedule.
///
/// The expression is checked **at build time** by the same parser the
/// scheduler runs, so a typo is a compile error naming the offending field
/// rather than a job that silently never fires:
///
/// ```swift
/// @Scheduled("0 0 3 * * *")               // 03:00 every day, UTC
/// @Scheduled("0 */15 * * * *")            // every fifteen minutes
/// @Scheduled("0 0 9 * * MON-FRI", timeZone: "America/New_York")
/// ```
///
/// Six fields, seconds first; the classic five-field crontab shape is also
/// accepted and means the same schedule at second zero.
///
/// - Parameters:
///   - cron: The schedule. Must be a string literal — that is what makes
///     build-time checking possible. For a schedule known only at runtime,
///     use `container.registerScheduledJob(_:cron:)`.
///   - timeZone: An IANA identifier. Defaults to UTC rather than the
///     machine's zone, so the same deployment behaves the same everywhere
///     and nobody discovers the difference during a daylight-saving change.
///   - onEveryNode: `false` — the default — means the job runs **once** per
///     firing, however many servers are running. On a single server that is
///     simply what happens; on several it needs a `JobCoordinator`, and the
///     scheduler says so loudly at startup if one is missing rather than
///     quietly running the job everywhere. Pass `true` for work that is
///     per-process by nature, like refreshing an in-memory cache.
///   - onOverlap: What to do when a firing arrives while the previous run is
///     still going. Defaults to skipping, because piling a second copy onto
///     a job that has grown slow is how a slow job becomes an outage.
@attached(peer)
public macro Scheduled(
    _ cron: String,
    timeZone: String = "UTC",
    onEveryNode: Bool = false,
    onOverlap: OverlapPolicy = .skip
) = #externalMacro(module: "FlightSchedulerMacrosImpl", type: "ScheduledMacro")

/// Runs a method on a fixed interval, measured from the end of the previous
/// run.
///
/// ```swift
/// @Scheduled(every: .minutes(5))
/// @Scheduled(every: .seconds(30), initialDelay: .seconds(10))
/// ```
///
/// From the *end* of the previous run, not the start: a job that takes
/// longer than its period would otherwise be perpetually late and eventually
/// overlapping, and "every five minutes" almost always means "with five
/// minutes of quiet in between".
///
/// Use a cron expression instead when the schedule is a wall-clock time —
/// intervals drift relative to the clock and know nothing about time zones.
@attached(peer)
public macro Scheduled(
    every period: Duration,
    initialDelay: Duration = .seconds(0),
    onEveryNode: Bool = false,
    onOverlap: OverlapPolicy = .skip
) = #externalMacro(module: "FlightSchedulerMacrosImpl", type: "ScheduledMacro")
