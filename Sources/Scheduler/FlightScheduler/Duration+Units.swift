import Foundation

extension Duration {
    /// `Duration` ships with seconds and smaller. A scheduler's natural units
    /// are minutes and hours, and `.seconds(3600)` at a call site is a thing
    /// the reader has to divide.
    ///
    /// Additive and namespaced to this module's importers. If another library
    /// in the same file defines the same member the result is an ambiguity
    /// the compiler reports, not a silent behaviour change — which is the
    /// acceptable failure mode for a convenience like this.
    public static func minutes(_ count: Int) -> Duration { .seconds(count * 60) }

    /// Hours, for the same reason as ``minutes(_:)``.
    public static func hours(_ count: Int) -> Duration { .seconds(count * 3600) }

    /// Days, as 24 hours exactly.
    ///
    /// Not a calendar day: across a daylight-saving change a civil day is 23
    /// or 25 hours, and this is 24 regardless. When you mean "every day at
    /// this wall-clock time", use a cron expression — that is precisely the
    /// difference between the two kinds of schedule.
    public static func days(_ count: Int) -> Duration { .seconds(count * 86_400) }
}

extension Duration {
    /// This duration in seconds, attoseconds included.
    ///
    /// `components.seconds` alone silently truncates: a scheduler that reads
    /// it turns `.milliseconds(500)` into zero — a job with no gap between
    /// firings — and `.milliseconds(1500)` into one second. Named rather than
    /// a `TimeInterval` initialiser so it cannot collide with anything else
    /// in an importer's file.
    var flightSeconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
