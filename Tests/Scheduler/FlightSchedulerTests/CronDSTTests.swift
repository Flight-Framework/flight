import Foundation
import Testing

@testable import FlightScheduler

/// Daylight saving, the two days a year a scheduler is actually interesting.
///
/// These pin the documented promises in `nextFireDate`. Both cases are ones
/// naive UTC arithmetic gets wrong: it either skips the job for a day or runs
/// it twice.
@Suite("Cron — daylight saving")
struct CronDSTTests {

    private let newYork = TimeZone(identifier: "America/New_York")!

    private func date(_ iso: String, _ zone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let p = iso.split(whereSeparator: { "-T:".contains($0) }).map { Int($0)! }
        return calendar.date(
            from: DateComponents(
                year: p[0], month: p[1], day: p[2], hour: p[3], minute: p[4], second: p[5]))!
    }

    private func render(_ d: Date, _ zone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: d)
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d",
            c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
    }

    @Test("spring forward: a job in the missing hour still runs that day")
    func springForward() throws {
        // 2026-03-08 in New York: 02:00 jumps straight to 03:00, so 02:30
        // does not exist. The job must still run — once — rather than being
        // silently skipped for the day.
        let cron = try CronExpression("0 30 2 * * *")
        let next = cron.nextFireDate(after: date("2026-03-07T12:00:00", newYork), in: newYork)!
        let rendered = render(next, newYork)
        #expect(rendered.hasPrefix("2026-03-08"), "ran on the right day, got \(rendered)")

        // And it does not then fire a second time later the same day.
        let after = cron.nextFireDate(after: next, in: newYork)!
        #expect(render(after, newYork).hasPrefix("2026-03-09"))
    }

    @Test("fall back: a job in the repeated hour runs once, not twice")
    func fallBack() throws {
        // 2026-11-01 in New York: 01:00–02:00 happens twice. "Daily at 01:30"
        // promised once a day, so exactly one firing must land on that date.
        let cron = try CronExpression("0 30 1 * * *")
        var t = date("2026-10-31T12:00:00", newYork)
        var onTheDay = 0
        for _ in 0..<4 {
            t = cron.nextFireDate(after: t, in: newYork)!
            if render(t, newYork).hasPrefix("2026-11-01") { onTheDay += 1 }
        }
        #expect(onTheDay == 1, "fired \(onTheDay) times on the fall-back day")
    }

    @Test("across a DST boundary a daily job stays at its wall-clock hour")
    func wallClockIsStable() throws {
        // The point of running in a zone rather than UTC: 03:00 local stays
        // 03:00 local, even though the UTC offset changed underneath.
        let cron = try CronExpression("0 0 3 * * *")
        var t = date("2026-03-06T00:00:00", newYork)
        var hours: [Int] = []
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = newYork
        for _ in 0..<5 {
            t = cron.nextFireDate(after: t, in: newYork)!
            hours.append(calendar.component(.hour, from: t))
        }
        #expect(hours == [3, 3, 3, 3, 3], "wall-clock hour drifted: \(hours)")
    }

    @Test("every firing is strictly increasing across a DST boundary")
    func monotonic() throws {
        // A schedule that ever goes backwards would re-run jobs. Walk a full
        // day either side of both transitions at minute resolution.
        let cron = try CronExpression("0 */20 * * * *")
        for start in ["2026-03-07T20:00:00", "2026-10-31T20:00:00"] {
            var t = date(start, newYork)
            for _ in 0..<200 {
                let next = cron.nextFireDate(after: t, in: newYork)!
                #expect(next > t, "went backwards at \(render(t, newYork))")
                t = next
            }
        }
    }
}
