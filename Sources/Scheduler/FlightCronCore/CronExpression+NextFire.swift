import Foundation

extension CronExpression {

    /// The first moment strictly after `date` that this expression matches,
    /// in `timeZone`.
    ///
    /// Strictly after, never equal: a scheduler that asked "what is next" from
    /// the instant a job just fired and got that same instant back would run
    /// it forever in a tight loop.
    ///
    /// Returns `nil` when the expression cannot match within four years —
    /// which is not a failure but a genuine answer for a schedule like
    /// `0 0 0 30 FEB *`. The search is bounded because an unbounded one would
    /// hang the scheduler thread instead of reporting the problem.
    ///
    /// ## Daylight saving
    ///
    /// The search walks calendar components in `timeZone` and asks Foundation
    /// to resolve each candidate, so the two awkward days behave the way an
    /// operator expects rather than the way naive UTC arithmetic would:
    ///
    /// - **Spring forward.** A daily 02:30 job on the day 02:00–03:00 does not
    ///   exist: Foundation resolves the missing time forward to 03:30, so the
    ///   job runs once, late, rather than being skipped for the day.
    /// - **Fall back.** A daily 01:30 job on the day 01:00–02:00 happens
    ///   twice: the first occurrence is taken and the second is not, because
    ///   the next search starts strictly after the first and the second
    ///   01:30 is no longer "after" in absolute terms once an hour has
    ///   elapsed. The job runs once, which is what "daily at 01:30" promised.
    ///   Asked from *inside* the repeated hour — a process that booted at
    ///   01:20 on the second pass — the first occurrence is already gone, so
    ///   the second one is the answer and the job still runs once that day.
    public func nextFireDate(after date: Date, in timeZone: TimeZone) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        // Start one second after: the resolution of the seconds field, and
        // what makes the result strictly later.
        let start = date.addingTimeInterval(1)
        let horizon = calendar.date(byAdding: .year, value: 4, to: start) ?? start
        var components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: start)

        // Walk the fields from coarse to fine. Each time a field is advanced,
        // everything finer resets to its minimum and the walk restarts — the
        // standard cron search, and the reason it terminates quickly rather
        // than testing every second.
        var guardCounter = 0
        while true {
            guardCounter += 1
            if guardCounter > 10_000 { return nil }

            guard let candidate = calendar.date(from: components) else {
                // Invalid wall-clock time (Feb 30, or a DST gap Foundation
                // will not resolve): advance a day and retry.
                components = advanceDay(components, calendar: calendar)
                continue
            }
            if candidate > horizon { return nil }

            let month = components.month ?? 1
            if !months.contains(month) {
                components = advanceMonth(components, calendar: calendar)
                continue
            }

            if !matchesDay(candidate, calendar: calendar) {
                components = advanceDay(components, calendar: calendar)
                continue
            }

            let hour = components.hour ?? 0
            if !hours.contains(hour) {
                guard let nextHour = hours.next(from: hour + 1, upperBound: 23) else {
                    components = advanceDay(components, calendar: calendar)
                    continue
                }
                components.hour = nextHour
                components.minute = minutes.first
                components.second = seconds.first
                continue
            }

            let minute = components.minute ?? 0
            if !minutes.contains(minute) {
                guard let nextMinute = minutes.next(from: minute + 1, upperBound: 59) else {
                    components = advanceHour(components, calendar: calendar)
                    continue
                }
                components.minute = nextMinute
                components.second = seconds.first
                continue
            }

            let second = components.second ?? 0
            if !seconds.contains(second) {
                guard let nextSecond = seconds.next(from: second + 1, upperBound: 59) else {
                    components = advanceMinute(components, calendar: calendar)
                    continue
                }
                components.second = nextSecond
                continue
            }

            // Every field matches. Re-resolve through the calendar so a DST
            // gap lands on the resolved instant rather than the nominal one.
            guard let resolved = calendar.date(from: components) else {
                components = advanceDay(components, calendar: calendar)
                continue
            }
            if resolved > date { return resolved }

            // `resolved` is not after `date`, so the wall-clock time matched
            // is one the fall-back hour repeats and Foundation resolved it to
            // the first pass, which has already gone by. This happens when
            // the query itself lands inside the second pass: a process
            // booting at 01:20 EST with a daily 01:30 job, or a run that
            // straddled the fold.
            //
            // Adding a second here — which is what this used to do — leaves
            // the answer an hour in the past, and the runner then sleeps for
            // no time at all, fires, recomputes the same past instant and
            // spins until real time leaves the fold.
            if let second = secondPass(matching: components, firstPass: resolved, in: calendar),
                second > date
            {
                return second
            }
            // Both passes are behind us. Keep walking rather than answering
            // with either.
            components = advanceSecond(components, calendar: calendar)
        }
    }

    /// The second occurrence of a wall-clock time the clocks repeat.
    ///
    /// `Calendar.date(from:)` always resolves an ambiguous time to the first
    /// pass, and offers no way to ask for the other one. So step forward by
    /// the transition's own shift and *check* that the components come back
    /// unchanged — the check is what makes this safe when the components were
    /// never ambiguous at all, or when the next transition is months away.
    ///
    /// Returns nil for a spring-forward transition, where nothing repeats.
    private func secondPass(
        matching components: DateComponents, firstPass: Date, in calendar: Calendar
    ) -> Date? {
        let zone = calendar.timeZone
        guard let transition = zone.nextDaylightSavingTimeTransition(after: firstPass)
        else { return nil }
        let shift = zone.secondsFromGMT(for: firstPass) - zone.secondsFromGMT(for: transition)
        guard shift > 0 else { return nil }

        let candidate = firstPass.addingTimeInterval(Double(shift))
        let round = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: candidate)
        guard round.year == components.year, round.month == components.month,
            round.day == components.day, round.hour == components.hour,
            round.minute == components.minute, round.second == components.second
        else { return nil }
        return candidate
    }

    /// Cron's day rule: when both day fields are narrowed they are OR'd, not
    /// AND'd. `0 0 0 1 * MON` fires on the 1st *and* on every Monday.
    private func matchesDay(_ date: Date, calendar: Calendar) -> Bool {
        let dayOfMonth = calendar.component(.day, from: date)
        // Foundation's weekday is 1-based with Sunday = 1; cron uses 0.
        let dayOfWeek = calendar.component(.weekday, from: date) - 1

        if bothDayFieldsRestricted {
            return daysOfMonth.contains(dayOfMonth) || daysOfWeek.contains(dayOfWeek)
        }
        return daysOfMonth.contains(dayOfMonth) && daysOfWeek.contains(dayOfWeek)
    }

    private func advanceSecond(_ c: DateComponents, calendar: Calendar) -> DateComponents {
        var next = c
        next.second = (c.second ?? 0) + 1
        return normalize(next, calendar: calendar)
    }

    private func advanceMinute(_ c: DateComponents, calendar: Calendar) -> DateComponents {
        var next = c
        next.second = seconds.first
        next.minute = (c.minute ?? 0) + 1
        return normalize(next, calendar: calendar)
    }

    private func advanceHour(_ c: DateComponents, calendar: Calendar) -> DateComponents {
        var next = c
        next.second = seconds.first
        next.minute = minutes.first
        next.hour = (c.hour ?? 0) + 1
        return normalize(next, calendar: calendar)
    }

    private func advanceDay(_ c: DateComponents, calendar: Calendar) -> DateComponents {
        var next = c
        next.second = seconds.first
        next.minute = minutes.first
        next.hour = hours.first
        next.day = (c.day ?? 1) + 1
        return normalize(next, calendar: calendar)
    }

    private func advanceMonth(_ c: DateComponents, calendar: Calendar) -> DateComponents {
        var next = c
        next.second = seconds.first
        next.minute = minutes.first
        next.hour = hours.first
        next.day = 1
        next.month = (c.month ?? 1) + 1
        return normalize(next, calendar: calendar)
    }

    /// Carries overflow (second 60, hour 24, day 32, month 13) into the next
    /// unit, arithmetically.
    ///
    /// Deliberately does **not** round-trip through `Calendar`. Doing that
    /// resolves daylight-saving gaps mid-search: advancing to 02:30 on a
    /// spring-forward day came back as 03:30, which then failed the hour
    /// test and skipped the whole day, so a daily 02:30 job silently did not
    /// run. The calendar resolves the gap exactly once, at the end, where
    /// that is the intended behaviour rather than a rewrite of the search
    /// state.
    private func normalize(_ c: DateComponents, calendar: Calendar) -> DateComponents {
        var year = c.year ?? 1970
        var month = c.month ?? 1
        var day = c.day ?? 1
        var hour = c.hour ?? 0
        var minute = c.minute ?? 0
        var second = c.second ?? 0

        if second > 59 { minute += second / 60; second %= 60 }
        if minute > 59 { hour += minute / 60; minute %= 60 }
        if hour > 23 { day += hour / 24; hour %= 24 }
        while month > 12 { month -= 12; year += 1 }
        while day > Self.daysInMonth(month: month, year: year) {
            day -= Self.daysInMonth(month: month, year: year)
            month += 1
            if month > 12 { month = 1; year += 1 }
        }
        return DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute, second: second)
    }

    /// Gregorian month lengths, computed rather than asked of `Calendar` —
    /// the point of `normalize` is to avoid the calendar's DST resolution.
    static func daysInMonth(month: Int, year: Int) -> Int {
        switch month {
        case 1, 3, 5, 7, 8, 10, 12: return 31
        case 4, 6, 9, 11: return 30
        case 2:
            let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
            return leap ? 29 : 28
        default: return 31
        }
    }
}
