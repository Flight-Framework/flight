import Foundation

/// A parsed cron expression, and the arithmetic for "when does this fire next".
///
/// Six fields, seconds first:
///
///     ┌───────────── second        (0–59)
///     │ ┌─────────── minute        (0–59)
///     │ │ ┌───────── hour          (0–23)
///     │ │ │ ┌─────── day of month  (1–31)
///     │ │ │ │ ┌───── month         (1–12, or JAN–DEC)
///     │ │ │ │ │ ┌─── day of week   (0–6, Sunday = 0, or SUN–SAT)
///     │ │ │ │ │ │
///     0 0 3 * * *      every day at 03:00:00
///
/// Seconds are the first field rather than absent because a scheduler without
/// sub-minute resolution cannot express "poll this every fifteen seconds",
/// which is a real thing applications need and the usual reason people give up
/// on a framework's scheduler and write their own loop.
///
/// A five-field expression — the classic crontab shape, no seconds — is also
/// accepted, and means the same thing it means everywhere else: fire at second
/// zero. `"0 3 * * *"` and `"0 0 3 * * *"` are the same schedule.
///
/// Each field accepts `*`, a number, a `a-b` range, an `a,b,c` list, and a
/// `*/n` or `a-b/n` step. That is the common subset every cron implementation
/// agrees on. Deliberately *not* supported, because implementations disagree
/// about what they mean and a schedule that silently means something different
/// than the reader expects is worse than one that fails to parse: `?`, `L`,
/// `W`, `#`, and `@yearly`-style nicknames.
public struct CronExpression: Sendable, Equatable, CustomStringConvertible {

    /// The literal text this was parsed from — what diagnostics and the
    /// actuator display, since it is what the author wrote.
    public let text: String

    let seconds: FieldSet
    let minutes: FieldSet
    let hours: FieldSet
    let daysOfMonth: FieldSet
    let months: FieldSet
    let daysOfWeek: FieldSet

    /// True when both day fields are restricted. Cron's oldest wart: when
    /// day-of-month and day-of-week are *both* narrowed, they combine with OR,
    /// not AND — `0 0 0 1 * MON` means "the 1st, and also every Monday".
    /// Every mainstream implementation agrees, and it surprises everyone.
    let bothDayFieldsRestricted: Bool

    public var description: String { text }

    // MARK: Parsing

    public init(_ text: String) throws {
        let fields = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let normalized: [String]
        switch fields.count {
        case 6: normalized = fields
        case 5: normalized = ["0"] + fields
        default:
            throw CronParseError(
                text: text,
                reason: """
                    expected 6 fields (second minute hour day-of-month month day-of-week) \
                    or 5 (the classic crontab shape, no seconds), found \(fields.count)
                    """)
        }

        self.text = text
        self.seconds = try FieldSet(normalized[0], range: 0...59, field: "second", in: text)
        self.minutes = try FieldSet(normalized[1], range: 0...59, field: "minute", in: text)
        self.hours = try FieldSet(normalized[2], range: 0...23, field: "hour", in: text)
        self.daysOfMonth = try FieldSet(
            normalized[3], range: 1...31, field: "day-of-month", in: text)
        self.months = try FieldSet(
            normalized[4], range: 1...12, field: "month", in: text, names: Self.monthNames)
        self.daysOfWeek = try FieldSet(
            normalized[5], range: 0...6, field: "day-of-week", in: text, names: Self.dayNames,
            normalize: { $0 == 7 ? 0 : $0 })  // both 0 and 7 mean Sunday
        self.bothDayFieldsRestricted = !daysOfMonth.isWildcard && !daysOfWeek.isWildcard
    }

    static let monthNames = [
        "JAN": 1, "FEB": 2, "MAR": 3, "APR": 4, "MAY": 5, "JUN": 6,
        "JUL": 7, "AUG": 8, "SEP": 9, "OCT": 10, "NOV": 11, "DEC": 12,
    ]
    static let dayNames = [
        "SUN": 0, "MON": 1, "TUE": 2, "WED": 3, "THU": 4, "FRI": 5, "SAT": 6,
    ]
}

/// Why a cron expression could not be parsed.
///
/// Carries the offending text and a reason naming the field, because the
/// message is read at a build failure — the macro validates expressions at
/// compile time — where the author has no debugger and only this string.
public struct CronParseError: Error, Equatable, CustomStringConvertible {
    public let text: String
    public let reason: String

    public var description: String { "invalid cron expression \"\(text)\": \(reason)" }
}

#if canImport(Foundation)
extension CronParseError: LocalizedError {
    public var errorDescription: String? { description }
}
#endif
