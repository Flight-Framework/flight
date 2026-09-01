// Every shape Docs/scheduler.md claims, compiled.
//
// A doc example that does not compile costs a reader the time to find out.
// This builds as part of `swift build`, so a rename that invalidates the
// prose breaks the build.

import FlightCore
import FlightScheduler
import Foundation

// snippet.hide
struct RoomActivity: Sendable {}

@Service(scope: .singleton)
struct ReportService {
    func rollUpYesterday() async throws {}
    func warmCache() async {}
}
// snippet.show

@Scheduler
struct ReportJobs {
    @Inject var reports: ReportService

    @Scheduled("0 0 3 * * *")
    func nightlyRollup() async throws {
        try await reports.rollUpYesterday()
    }

    @Scheduled(every: .minutes(5), onEveryNode: true)
    func refreshCache() async throws {
        await reports.warmCache()
    }
}

// The overlap and time-zone options the doc mentions.
@Scheduler
struct MoreJobs {
    @Scheduled("0 0 9 * * MON-FRI", timeZone: "America/New_York")
    func weekdayMorning() {}

    @Scheduled(every: .seconds(30), initialDelay: .seconds(10), onOverlap: .queue)
    func drain() async {}

    @Scheduled("0 */15 * * * *")
    func quarterHourly() {}
}

// The five-field crontab shape means the same schedule at second zero.
func scheduleShapes() throws {
    let six = try CronExpression("0 0 3 * * *")
    let five = try CronExpression("0 3 * * *")
    let from = Date(timeIntervalSince1970: 0)
    precondition(
        six.nextFireDate(after: from, in: .gmt) == five.nextFireDate(after: from, in: .gmt))

    // Refused rather than guessed at.
    for unsupported in ["0 0 0 L * *", "@daily", "0 0 0 * * 6#3"] {
        var refused = false
        do { _ = try CronExpression(unsupported) } catch { refused = true }
        precondition(refused, "\(unsupported) should not parse")
    }
}

// Observing, as the doc shows it.
func statusShapes(status: SchedulerStatus) {
    let all: [JobStatus] = status.snapshot()
    precondition(all.map(\.name) == all.map(\.name).sorted())
    _ = status.mode
}
