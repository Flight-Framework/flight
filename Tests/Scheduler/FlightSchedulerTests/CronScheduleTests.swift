import Foundation
import Testing

@testable import FlightScheduler

@Suite("Cron — when it fires")
struct CronScheduleTests {

    private let utc = TimeZone(identifier: "UTC")!

    private func date(_ iso: String, _ zone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = iso.split(whereSeparator: { "-T:".contains($0) }).map { Int($0)! }
        return calendar.date(
            from: DateComponents(
                year: parts[0], month: parts[1], day: parts[2],
                hour: parts[3], minute: parts[4], second: parts[5]))!
    }

    private func render(_ d: Date, _ zone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: d)
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d",
            c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
    }

    @Test("a daily job fires at the stated hour")
    func daily() throws {
        let cron = try CronExpression("0 0 3 * * *")
        let next = cron.nextFireDate(after: date("2026-03-10T12:00:00", utc), in: utc)!
        #expect(render(next, utc) == "2026-03-11T03:00:00")
    }

    @Test("the answer is strictly after the instant asked about")
    func strictlyAfter() throws {
        // Asking from exactly a firing instant must not return that instant,
        // or a scheduler that asks "what is next" after running would spin.
        let cron = try CronExpression("0 0 3 * * *")
        let firing = date("2026-03-10T03:00:00", utc)
        let next = cron.nextFireDate(after: firing, in: utc)!
        #expect(next > firing)
        #expect(render(next, utc) == "2026-03-11T03:00:00")
    }

    @Test("every fifteen seconds — the sub-minute case seconds exist for")
    func subMinute() throws {
        let cron = try CronExpression("*/15 * * * * *")
        var t = date("2026-03-10T12:00:00", utc)
        var seen: [String] = []
        for _ in 0..<5 {
            t = cron.nextFireDate(after: t, in: utc)!
            seen.append(render(t, utc))
        }
        #expect(seen == [
            "2026-03-10T12:00:15", "2026-03-10T12:00:30", "2026-03-10T12:00:45",
            "2026-03-10T12:01:00", "2026-03-10T12:01:15",
        ])
    }

    @Test("a list and a range combine")
    func listAndRange() throws {
        let cron = try CronExpression("0 0 9-11,17 * * *")
        var t = date("2026-03-10T00:00:00", utc)
        var hours: [Int] = []
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        for _ in 0..<4 {
            t = cron.nextFireDate(after: t, in: utc)!
            hours.append(calendar.component(.hour, from: t))
        }
        #expect(hours == [9, 10, 11, 17])
    }

    @Test("both day fields narrowed means OR, not AND — cron's oldest wart")
    func dayFieldsOr() throws {
        // "the 1st, and also every Monday" — every mainstream cron agrees,
        // and it surprises everyone, so it is pinned.
        let cron = try CronExpression("0 0 0 1 * MON")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        var t = date("2026-06-01T12:00:00", utc)  // a Monday, the 1st
        var days: [Int] = []
        for _ in 0..<4 {
            t = cron.nextFireDate(after: t, in: utc)!
            days.append(calendar.component(.day, from: t))
        }
        // June 2026: Mondays fall on the 8th, 15th, 22nd, 29th.
        #expect(days == [8, 15, 22, 29])
    }

    @Test("only one day field narrowed means plain AND")
    func singleDayFieldAnds() throws {
        let cron = try CronExpression("0 0 0 15 * *")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let next = cron.nextFireDate(after: date("2026-06-01T00:00:00", utc), in: utc)!
        #expect(calendar.component(.day, from: next) == 15)
    }

    @Test("a schedule that can never match returns nil rather than hanging")
    func impossibleSchedule() throws {
        // 30 February. The search is bounded on purpose: an unbounded one
        // would hang the scheduler thread instead of reporting the problem.
        let cron = try CronExpression("0 0 0 30 2 *")
        #expect(cron.nextFireDate(after: date("2026-01-01T00:00:00", utc), in: utc) == nil)
    }

    @Test("February 29 finds the next leap year")
    func leapDay() throws {
        let cron = try CronExpression("0 0 0 29 2 *")
        let next = cron.nextFireDate(after: date("2026-03-01T00:00:00", utc), in: utc)!
        #expect(render(next, utc) == "2028-02-29T00:00:00")
    }

    @Test("the schedule follows its own time zone, not the machine's")
    func honoursTimeZone() throws {
        let cron = try CronExpression("0 0 3 * * *")
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        let next = cron.nextFireDate(after: date("2026-06-10T12:00:00", tokyo), in: tokyo)!
        #expect(render(next, tokyo) == "2026-06-11T03:00:00")
        // Same instant expressed in UTC is 18:00 the previous day (JST = +9).
        #expect(render(next, utc) == "2026-06-10T18:00:00")
    }
}
