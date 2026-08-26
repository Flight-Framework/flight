import Foundation
import HTTPTypes

// The conditional-request and range state machine, as a function over a
// sized byte source — Go's `ServeContent` decomposition. Everything here is
// deliberately independent of the filesystem: the same tested logic serves a
// file, a database blob, and a generated document, and the file-specific
// parts (identity, policy, lookup) live with `FileByteSource` and the asset
// layer instead.
//
// The RFC edges below are each a place a production Swift framework was
// found wrong in August 2026 — suffix ranges served from the wrong end,
// range ends past EOF rejected instead of clamped, 416 never emitted,
// `If-Modified-Since` ignored while `Last-Modified` was emitted, multi-value
// `If-None-Match` never matching. The test suite pins every one.

/// An HTTP entity tag: the opaque value (unquoted) plus its weakness.
public struct EntityTag: Sendable, Equatable {
    public let value: String
    public let isWeak: Bool

    public init(_ value: String, weak: Bool = false) {
        self.value = value
        self.isWeak = weak
    }

    /// The wire form: `"value"` or `W/"value"`.
    public var headerValue: String {
        (isWeak ? "W/" : "") + "\"\(value)\""
    }

    /// The default validator for a file: device, inode, size, and
    /// full-resolution mtime. Weak, honestly — mtime+identity says "probably
    /// unchanged", not "byte-identical" — but built from nanoseconds and the
    /// inode, so a same-second rewrite or an atomic replace-by-rename gets a
    /// new tag where an mtime-seconds validator would lie.
    public static func file(_ source: FileByteSource) -> EntityTag {
        EntityTag(
            String(source.deviceID, radix: 16) + "-" + String(source.inode, radix: 16)
                + "-" + String(UInt64(bitPattern: source.count), radix: 16)
                + "-" + String(UInt64(bitPattern: source.modificationNanoseconds), radix: 16),
            weak: true)
    }

    /// Weak comparison (RFC 9110 §8.8.3.2): opaque values compared, weakness
    /// ignored. What `If-None-Match` uses.
    public func weaklyMatches(_ other: EntityTag) -> Bool {
        value == other.value
    }

    /// Strong comparison: equal and *neither* weak. What `If-Range` demands
    /// — resuming a download against a "probably unchanged" file is how
    /// silently corrupt files happen.
    public func stronglyMatches(_ other: EntityTag) -> Bool {
        !isWeak && !other.isWeak && value == other.value
    }
}

/// What `serveContent` needs to know about the bytes it is serving. The
/// caller supplies validators rather than this layer inventing them —
/// a policy Go's ServeContent got right: what an ETag *means* depends on
/// where the bytes came from, and only the caller knows that.
public struct ContentDescriptor: Sendable {
    public var source: any ByteSource
    /// Sent as `Content-Type` when present; omitted entirely when nil. No
    /// content sniffing — a wrong guess is worse than no header, and the
    /// asset layer has the filename to decide from.
    public var contentType: String?
    public var modificationDate: Date?
    public var etag: EntityTag?
    public var cacheControl: String?
    /// Merged into the response (`Vary`, `Content-Disposition`, …). The
    /// computed headers win on collision.
    public var extraHeaders: HTTPFields
    public var chunkSize: Int

    public init(
        source: any ByteSource,
        contentType: String? = nil,
        modificationDate: Date? = nil,
        etag: EntityTag? = nil,
        cacheControl: String? = nil,
        extraHeaders: HTTPFields = [:],
        chunkSize: Int = FileByteSource.defaultChunkSize
    ) {
        self.source = source
        self.contentType = contentType
        self.modificationDate = modificationDate
        self.etag = etag
        self.cacheControl = cacheControl
        self.extraHeaders = extraHeaders
        self.chunkSize = chunkSize
    }

    /// A descriptor for an open file, with the default validators filled in
    /// from the descriptor's own fstat — the common case in one call.
    public static func file(
        _ source: FileByteSource,
        contentType: String? = nil,
        cacheControl: String? = nil
    ) -> ContentDescriptor {
        ContentDescriptor(
            source: source,
            contentType: contentType,
            modificationDate: source.modificationDate,
            etag: .file(source),
            cacheControl: cacheControl)
    }
}

/// Serves `content` for `request` with full conditional-request and range
/// semantics: `If-None-Match` (list and `*`, weak comparison),
/// `If-Modified-Since`, single byte ranges including suffix ranges, range
/// ends clamped to EOF, `If-Range` (strong ETag or exact date), `416` with
/// `Content-Range: bytes */size` for unsatisfiable ranges, and `HEAD`
/// answered with the exact headers of the corresponding GET — `206` and
/// `Content-Range` included — with no bytes ever read.
///
/// Methods other than GET/HEAD get the full representation with no
/// conditional or range processing: this function serves reads; the
/// state-changing preconditions (`If-Match`, `If-Unmodified-Since`) belong
/// to write handlers and are deliberately out of scope.
///
/// A syntactically invalid, multi-range, or non-`bytes` `Range` header is
/// *ignored* — full 200 — per RFC 9110's option, rather than rejected: a
/// server refusing `bytes=0-999999999` (the standard resumability probe)
/// with a 400 breaks well-behaved clients.
public func serveContent(for request: Request, _ content: ContentDescriptor) -> Response {
    let size = content.source.count

    var headers = content.extraHeaders
    if let contentType = content.contentType {
        headers[.contentType] = contentType
    }
    if let cacheControl = content.cacheControl {
        headers[.cacheControl] = cacheControl
    }
    if let etag = content.etag {
        headers[.eTag] = etag.headerValue
    }
    if let modified = content.modificationDate {
        headers[.lastModified] = HTTPDate.format(modified)
    }
    headers[.acceptRanges] = "bytes"

    let isRead = request.method == .get || request.method == .head
    guard isRead else {
        return fullResponse(headers: headers, content: content, size: size)
    }

    // Conditionals, in RFC 9110 §13.2.2 order for a cache-validating read:
    // If-None-Match wins over If-Modified-Since when both are present.
    if let rawIfNoneMatch = request.headers[.ifNoneMatch] {
        if let condition = IfNoneMatch(rawIfNoneMatch),
            condition.matches(content.etag)
        {
            return notModified(headers: headers, size: size)
        }
        // Present but unmatched (or unparseable): fall through — and
        // deliberately do NOT consult If-Modified-Since, per the RFC.
    } else if let rawIfModifiedSince = request.headers[.ifModifiedSince],
        let since = HTTPDate.parse(rawIfModifiedSince),
        let modified = content.modificationDate,
        // Second granularity: Last-Modified has one-second resolution on
        // the wire, so the comparison must too, or a fractional mtime makes
        // every revalidation miss by microseconds.
        modified.timeIntervalSince1970.rounded(.down) <= since.timeIntervalSince1970.rounded(.down)
    {
        return notModified(headers: headers, size: size)
    }

    // Ranges.
    if let rawRange = request.headers[.range], let requested = RequestedByteRange(rawRange) {
        // If-Range: "give me the range if unchanged, the whole thing if
        // not" — evaluated only when Range is present. A failed match
        // silently downgrades to the full response, never an error.
        if let rawIfRange = request.headers[.ifRange] {
            guard ifRangeMatches(rawIfRange, etag: content.etag, modified: content.modificationDate)
            else {
                return fullResponse(headers: headers, content: content, size: size)
            }
        }

        switch requested.resolve(against: size) {
        case .satisfiable(let range):
            headers[.contentRange] = "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(size)"
            headers[.contentLength] = "\(range.count)"
            return .file(
                FileResponse(
                    status: .partialContent, headers: headers, source: content.source,
                    range: range, chunkSize: content.chunkSize))
        case .unsatisfiable:
            var failureHeaders = content.extraHeaders
            failureHeaders[.contentRange] = "bytes */\(size)"
            failureHeaders[.contentLength] = "0"
            return .fixed(status: .rangeNotSatisfiable, headers: failureHeaders, body: Data())
        }
    }

    return fullResponse(headers: headers, content: content, size: size)
}

private func fullResponse(headers: HTTPFields, content: ContentDescriptor, size: Int64) -> Response {
    var headers = headers
    headers[.contentLength] = "\(size)"
    return .file(
        FileResponse(
            status: .ok, headers: headers, source: content.source,
            range: 0..<size, chunkSize: content.chunkSize))
}

/// RFC 9110 §15.4.5: a 304 carries the validator and cache metadata the 200
/// would have — the client's stored representation stays authoritative for
/// everything else.
private func notModified(headers: HTTPFields, size: Int64) -> Response {
    var kept: HTTPFields = [:]
    for name in [HTTPField.Name.eTag, .lastModified, .cacheControl, .vary, .expires] {
        if let value = headers[name] { kept[name] = value }
    }
    kept[.contentLength] = "\(size)"
    return .fixed(status: .notModified, headers: kept, body: Data())
}

private func ifRangeMatches(_ raw: String, etag: EntityTag?, modified: Date?) -> Bool {
    let trimmed = raw.trimmingCharacters(in: .whitespaces)
    if trimmed.hasPrefix("\"") || trimmed.hasPrefix("W/") {
        guard let requested = EntityTag.parseOne(trimmed), let etag else { return false }
        return etag.stronglyMatches(requested)
    }
    // Date form: honored only on an exact second-for-second match with the
    // representation's own Last-Modified.
    guard let requestedDate = HTTPDate.parse(trimmed), let modified else { return false }
    return requestedDate.timeIntervalSince1970 == modified.timeIntervalSince1970.rounded(.down)
}

// MARK: - If-None-Match

/// A parsed `If-None-Match`: `*`, or a list of entity tags. The parser is
/// quoted-string aware — an ETag's opaque value may legally contain a comma,
/// so splitting the header on commas first (the common shortcut) corrupts
/// exactly the tags it most needs to match.
struct IfNoneMatch {
    let star: Bool
    let tags: [EntityTag]

    init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed == "*" {
            self.star = true
            self.tags = []
            return
        }
        var tags: [EntityTag] = []
        var rest = Substring(trimmed)
        while true {
            rest = rest.drop { $0 == " " || $0 == "\t" || $0 == "," }
            if rest.isEmpty { break }
            guard let (tag, remainder) = EntityTag.parsePrefix(of: rest) else { return nil }
            tags.append(tag)
            rest = remainder
        }
        guard !tags.isEmpty else { return nil }
        self.star = false
        self.tags = tags
    }

    func matches(_ etag: EntityTag?) -> Bool {
        if star { return true }
        guard let etag else { return false }
        return tags.contains { $0.weaklyMatches(etag) }
    }
}

extension EntityTag {
    /// Parses exactly one wire-form entity tag (`"v"` or `W/"v"`).
    static func parseOne(_ raw: String) -> EntityTag? {
        guard let (tag, rest) = parsePrefix(of: Substring(raw)),
            rest.drop(while: { $0 == " " || $0 == "\t" }).isEmpty
        else { return nil }
        return tag
    }

    /// Parses one entity tag from the front of `input`, returning it and
    /// what follows the closing quote.
    static func parsePrefix(of input: Substring) -> (EntityTag, Substring)? {
        var rest = input
        var weak = false
        if rest.hasPrefix("W/") {
            weak = true
            rest = rest.dropFirst(2)
        }
        guard rest.first == "\"" else { return nil }
        rest = rest.dropFirst()
        guard let closingQuote = rest.firstIndex(of: "\"") else { return nil }
        let value = String(rest[..<closingQuote])
        return (EntityTag(value, weak: weak), rest[rest.index(after: closingQuote)...])
    }
}

// MARK: - Range

/// One requested byte range, in the three RFC 9110 §14.1.2 forms. Modeled
/// explicitly because the suffix form is where implementations go wrong:
/// `bytes=-500` means the LAST 500 bytes, and at least one production Swift
/// framework serves the first 501 — with a test suite pinning the mistake.
enum RequestedByteRange: Equatable {
    /// `bytes=500-999` or `bytes=500-` (open end).
    case from(Int64, throughInclusive: Int64?)
    /// `bytes=-500`: the final N bytes of the representation.
    case suffix(Int64)

    /// nil = the header is not a single well-formed bytes-range — multi
    /// -range, another unit, garbage — and per RFC 9110 the server ignores
    /// it and serves the full representation.
    init?(_ raw: String) {
        var rest = Substring(raw.trimmingCharacters(in: .whitespaces))
        // The range unit is case-sensitive in the grammar; be lenient about
        // it anyway — a client saying "Bytes=" means bytes.
        guard rest.count > 6, rest.prefix(6).lowercased() == "bytes=" else { return nil }
        rest = rest.dropFirst(6)
        guard !rest.contains(",") else { return nil }  // multi-range → ignore
        guard let dash = rest.firstIndex(of: "-") else { return nil }
        let firstPart = rest[..<dash].trimmingCharacters(in: .whitespaces)
        let secondPart = rest[rest.index(after: dash)...].trimmingCharacters(in: .whitespaces)

        func digits(_ s: String) -> Int64? {
            guard !s.isEmpty, s.allSatisfy(\.isNumber) else { return nil }
            return Int64(s)
        }

        if firstPart.isEmpty {
            guard let n = digits(secondPart) else { return nil }
            self = .suffix(n)
        } else if secondPart.isEmpty {
            guard let start = digits(firstPart) else { return nil }
            self = .from(start, throughInclusive: nil)
        } else {
            guard let start = digits(firstPart), let end = digits(secondPart), start <= end
            else { return nil }
            self = .from(start, throughInclusive: end)
        }
    }

    enum Resolution: Equatable {
        case satisfiable(Range<Int64>)
        case unsatisfiable
    }

    /// Resolves against a representation of `size` bytes, half-open.
    /// - An end past the last byte is *clamped*, per the RFC — `bytes=0-` and
    ///   `bytes=0-999999999` are how clients probe resumability, and
    ///   rejecting them breaks curl and every media player.
    /// - A start at or past the size — and any range against an empty
    ///   representation — is unsatisfiable: 416, never a negative length.
    func resolve(against size: Int64) -> Resolution {
        switch self {
        case .suffix(let n):
            guard n > 0, size > 0 else { return .unsatisfiable }
            return .satisfiable(max(0, size - n)..<size)
        case .from(let start, let throughInclusive):
            guard start < size else { return .unsatisfiable }
            let endExclusive = throughInclusive.map { min($0 + 1, size) } ?? size
            return .satisfiable(start..<endExclusive)
        }
    }
}

// MARK: - HTTP dates

/// IMF-fixdate formatting and three-format parsing (RFC 9110 §5.6.7),
/// hand-rolled: `DateFormatter` is not `Sendable`, allocates per use, and
/// has Linux locale quirks — while an HTTP date is pure integer arithmetic
/// in a fixed calendar. Conversions use the standard civil-date algorithms.
public enum HTTPDate {
    private static let months = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun",
        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    ]
    private static let weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    /// `Sun, 06 Nov 1994 08:49:37 GMT`
    public static func format(_ date: Date) -> String {
        let seconds = Int64(date.timeIntervalSince1970.rounded(.down))
        let days = seconds.quotientFlooring(86_400)
        let secondOfDay = seconds - days * 86_400
        let (year, month, day) = civil(fromDays: days)
        let weekday = weekdays[Int((days % 7 + 11) % 7)]  // 1970-01-01 = Thursday
        return String(
            format: "%@, %02d %@ %04d %02d:%02d:%02d GMT",
            weekday, day, months[month - 1], year,
            secondOfDay / 3_600, (secondOfDay / 60) % 60, secondOfDay % 60)
    }

    /// Accepts the three obs-forms every server must read: IMF-fixdate,
    /// RFC 850, and asctime.
    public static func parse(_ raw: String) -> Date? {
        let tokens = raw.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
        switch tokens.count {
        case 6 where tokens[5] == "GMT":
            // IMF: ["Sun", "06", "Nov", "1994", "08:49:37", "GMT"]
            guard let day = Int(tokens[1]), let month = month(tokens[2]),
                let year = Int(tokens[3]), let time = clock(tokens[4])
            else { return nil }
            return date(year: year, month: month, day: day, time: time)
        case 4 where tokens[3] == "GMT":
            // RFC 850: ["Sunday", "06-Nov-94", "08:49:37", "GMT"]
            let dateParts = tokens[1].split(separator: "-").map(String.init)
            guard dateParts.count == 3, let day = Int(dateParts[0]),
                let month = month(dateParts[1]), let shortYear = Int(dateParts[2]),
                let time = clock(tokens[2])
            else { return nil }
            let year = shortYear >= 70 ? 1900 + shortYear : 2000 + shortYear
            return date(year: year, month: month, day: day, time: time)
        case 5:
            // asctime: ["Sun", "Nov", "6", "08:49:37", "1994"]
            guard let month = month(tokens[1]), let day = Int(tokens[2]),
                let time = clock(tokens[3]), let year = Int(tokens[4])
            else { return nil }
            return date(year: year, month: month, day: day, time: time)
        default:
            return nil
        }
    }

    private static func month(_ token: String) -> Int? {
        months.firstIndex(of: token).map { $0 + 1 }
    }

    private static func clock(_ token: String) -> (Int, Int, Int)? {
        let parts = token.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 3,
            (0...23).contains(parts[0]), (0...59).contains(parts[1]), (0...60).contains(parts[2])
        else { return nil }
        return (parts[0], parts[1], parts[2])
    }

    private static func date(year: Int, month: Int, day: Int, time: (Int, Int, Int)) -> Date? {
        guard (1...12).contains(month), (1...31).contains(day) else { return nil }
        let days = days(fromCivilYear: year, month: month, day: day)
        let seconds = days * 86_400 + Int64(time.0) * 3_600 + Int64(time.1) * 60 + Int64(time.2)
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    // Howard Hinnant's civil-date algorithms — exact over the proleptic
    // Gregorian calendar, no lookup tables, no Foundation.
    private static func days(fromCivilYear y: Int, month m: Int, day d: Int) -> Int64 {
        let y = Int64(m <= 2 ? y - 1 : y)
        let era = (y >= 0 ? y : y - 399).quotientFlooring(400)
        let yoe = y - era * 400
        let doy = Int64((153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1)
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    private static func civil(fromDays z: Int64) -> (year: Int, month: Int, day: Int) {
        let z = z + 719_468
        let era = (z >= 0 ? z : z - 146_096).quotientFlooring(146_097)
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (Int(m <= 2 ? y + 1 : y), Int(m), Int(d))
    }
}

extension Int64 {
    /// Floor division — Swift's `/` truncates toward zero, and every date
    /// algorithm above needs the mathematical floor for negative values.
    fileprivate func quotientFlooring(_ divisor: Int64) -> Int64 {
        let q = self / divisor
        return (self % divisor != 0 && (self < 0) != (divisor < 0)) ? q - 1 : q
    }
}
