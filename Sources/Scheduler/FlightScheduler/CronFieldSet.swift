import Foundation

/// One cron field, as the set of values it matches.
///
/// A bitmask rather than a `Set<Int>`: every field is bounded (0–59 at
/// widest), matching is the innermost operation of the next-fire search, and
/// a 64-bit test is one instruction where a hash lookup is not.
struct FieldSet: Sendable, Equatable {
    private let mask: UInt64
    let isWildcard: Bool

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
                if stepParts.count == 1 { wildcard = true }
            } else if base.contains("-") {
                let ends = base.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
                guard ends.count == 2 else { throw fail("\"\(base)\" is not a range") }
                low = try value(ends[0])
                high = try value(ends[1])
                guard low <= high else {
                    throw fail("range \"\(base)\" runs backwards; wrapping ranges are not supported")
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
    }
}
