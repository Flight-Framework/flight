/// One cron field, as the set of values it matches.
///
/// A bitmask rather than a `Set<Int>`: every field is bounded (0–59 at
/// widest), matching is the innermost operation of the next-fire search, and
/// a 64-bit test is one instruction where a hash lookup is not.
struct FieldSet: Sendable, Equatable {
    private let mask: UInt64
    let isWildcard: Bool
    /// True for a `*/n` term — a wildcard narrowed by a step.
    ///
    /// Not the same as `isWildcard`, and the difference matters only for
    /// cron's day rule, where implementations genuinely disagree about
    /// whether `*/2` counts as "restricted". Recorded here so
    /// ``CronExpression`` can refuse the one shape it makes ambiguous
    /// rather than pick a side silently.
    let hasSteppedWildcard: Bool

    func contains(_ value: Int) -> Bool {
        guard value >= 0, value < 64 else { return false }
        return mask & (1 << UInt64(value)) != 0
    }

    /// The smallest matching value >= `value`, or nil if none remain.
    func next(from value: Int, upperBound: Int) -> Int? {
        var candidate = max(value, 0)
        while candidate <= upperBound {
            if contains(candidate) { return candidate }
            candidate += 1
        }
        return nil
    }

    var first: Int { (0...63).first(where: contains) ?? 0 }

    init(
        _ text: String,
        range: ClosedRange<Int>,
        field: String,
        in expression: String,
        names: [String: Int] = [:],
        normalize: (Int) -> Int = { $0 }
    ) throws {
        func fail(_ reason: String) -> CronParseError {
            CronParseError(text: expression, reason: "\(field): \(reason)")
        }
        func value(_ token: String) throws -> Int {
            if let named = names[token.uppercased()] { return normalize(named) }
            guard let n = Int(token) else {
                let hint = names.isEmpty ? "" : " (or one of \(names.keys.sorted().joined(separator: ", ")))"
                throw fail("\"\(token)\" is not a number\(hint)")
            }
            let normalized = normalize(n)
            guard range.contains(normalized) else {
                throw fail("\(n) is out of range \(range.lowerBound)–\(range.upperBound)")
            }
            return normalized
        }

        var bits: UInt64 = 0
        var wildcard = false
        var steppedWildcard = false

        for term in text.split(separator: ",", omittingEmptySubsequences: false).map(String.init) {
            guard !term.isEmpty else { throw fail("empty term in \"\(text)\"") }

            // Split an optional `/step` suffix.
            let stepParts = term.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard stepParts.count <= 2 else { throw fail("\"\(term)\" has more than one step") }
            var step = 1
            if stepParts.count == 2 {
                guard let parsed = Int(stepParts[1]), parsed > 0 else {
                    throw fail("step in \"\(term)\" must be a positive number")
                }
                step = parsed
            }

            let base = stepParts[0]
            var low: Int
            var high: Int
            if base == "*" {
                low = range.lowerBound
                high = range.upperBound
                if stepParts.count == 1 { wildcard = true } else { steppedWildcard = true }
            } else if base.contains("-") {
                let ends = base.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
                guard ends.count == 2 else { throw fail("\"\(base)\" is not a range") }
                low = try value(ends[0])
                high = try value(ends[1])
                // Sunday is spelled both 0 and 7. Normalizing 7 to 0 before
                // the range check turned `5-7` — Friday through Sunday, which
                // Vixie accepts — into a backwards range, diagnosed with a
                // message about wrapping the author never wrote. Read a
                // literal 7 at the top of a range as the end of the week and
                // walk the raw values, normalizing each.
                if high < low, Int(ends[1]) == range.upperBound + 1 {
                    var v = low
                    while v <= range.upperBound + 1 {
                        bits |= (1 << UInt64(normalize(v)))
                        v += step
                    }
                    continue
                }
                guard low <= high else {
                    // Spelled back in the author's own alphabet: a suggestion
                    // that answers "FRI-TUE" with "FRI-6,0-TUE" is a second
                    // puzzle, not a fix.
                    let usedNames = Int(ends[0]) == nil
                    func spell(_ v: Int) -> String {
                        guard usedNames, let name = names.first(where: { $0.value == v })?.key
                        else { return "\(v)" }
                        return name
                    }
                    throw fail(
                        """
                        range "\(base)" runs backwards; wrapping ranges are not supported — \
                        write it as two terms, \
                        "\(ends[0])-\(spell(range.upperBound)),\(spell(range.lowerBound))-\(ends[1])"
                        """)
                }
            } else {
                low = try value(base)
                // A bare value with a step means "from here to the end" — the
                // widespread reading of `5/10`, and what `*/n` reduces to.
                high = stepParts.count == 2 ? range.upperBound : low
            }

            var v = low
            while v <= high {
                bits |= (1 << UInt64(v))
                v += step
            }
        }

        guard bits != 0 else { throw fail("matches nothing") }
        self.mask = bits
        self.isWildcard = wildcard
        self.hasSteppedWildcard = steppedWildcard
    }
}
