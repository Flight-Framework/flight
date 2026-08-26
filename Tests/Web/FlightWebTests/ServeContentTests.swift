import Foundation
import FlightWeb
import FlightWebTesting
import HTTPTypes
import Testing

// Every numbered oddity below is a real defect found in a production Swift
// framework's file serving in August 2026. This suite is the reason Flight's
// implementation can claim to be correct rather than merely present.

private let body = Data("abcdefghijklmnopqrstuvwxyz".utf8)  // 26 bytes

private func request(
    _ method: HTTPRequest.Method = .get, headers: HTTPFields = [:]
) -> Request {
    Request(method: method, path: "/asset", headers: headers)
}

private func descriptor(
    etag: EntityTag? = EntityTag("v1"),
    modified: Date? = Date(timeIntervalSince1970: 1_700_000_000),
    cacheControl: String? = nil
) -> ContentDescriptor {
    ContentDescriptor(
        source: DataByteSource(body),
        contentType: "text/plain",
        modificationDate: modified,
        etag: etag,
        cacheControl: cacheControl)
}

private func collected(_ response: Response) async throws -> Data {
    try await response.collectedBody()
}

@Suite("serveContent — ranges")
struct ServeContentRangeTests {

    @Test("a suffix range serves the LAST n bytes, not the first")
    func suffixRangeServesTheTail() async throws {
        // The defect enshrined in a shipping framework's own test suite:
        // bytes=-4 served as 0...4. RFC 9110 §14.1.2: it is the final 4.
        let response = serveContent(
            for: request(headers: [.range: "bytes=-4"]), descriptor())
        #expect(response.status == .partialContent)
        #expect(response.headers[.contentRange] == "bytes 22-25/26")
        #expect(try await collected(response) == Data("wxyz".utf8))
    }

    @Test("an end past the last byte is clamped, not rejected")
    func overlongEndIsClamped() async throws {
        // `bytes=0-999999999` is how curl and media players probe
        // resumability; one framework answers it 400.
        let response = serveContent(
            for: request(headers: [.range: "bytes=10-999999999"]), descriptor())
        #expect(response.status == .partialContent)
        #expect(response.headers[.contentRange] == "bytes 10-25/26")
        #expect(response.headers[.contentLength] == "16")
        #expect(try await collected(response) == Data("klmnopqrstuvwxyz".utf8))
    }

    @Test("a start at or past the size is 416 with the size advertised")
    func startPastEndIs416() async throws {
        // One framework produces a negative Content-Length here; another a
        // 400. RFC 9110 §15.5.17: 416 with `Content-Range: bytes */size`.
        let response = serveContent(
            for: request(headers: [.range: "bytes=26-"]), descriptor())
        #expect(response.status == .rangeNotSatisfiable)
        #expect(response.headers[.contentRange] == "bytes */26")
        #expect(try await collected(response).isEmpty)
    }

    @Test("bytes=-0 is unsatisfiable")
    func suffixZeroIs416() {
        let response = serveContent(
            for: request(headers: [.range: "bytes=-0"]), descriptor())
        #expect(response.status == .rangeNotSatisfiable)
    }

    @Test("a suffix longer than the file is the whole file, as a 206")
    func suffixLongerThanFile() async throws {
        let response = serveContent(
            for: request(headers: [.range: "bytes=-100"]), descriptor())
        #expect(response.status == .partialContent)
        #expect(response.headers[.contentRange] == "bytes 0-25/26")
        #expect(try await collected(response) == body)
    }

    @Test("open-ended, bounded, and exact ranges resolve correctly")
    func ordinaryForms() async throws {
        let openEnded = serveContent(
            for: request(headers: [.range: "bytes=20-"]), descriptor())
        #expect(try await collected(openEnded) == Data("uvwxyz".utf8))

        let bounded = serveContent(
            for: request(headers: [.range: "bytes=1-3"]), descriptor())
        #expect(bounded.headers[.contentRange] == "bytes 1-3/26")
        #expect(try await collected(bounded) == Data("bcd".utf8))

        let singleByte = serveContent(
            for: request(headers: [.range: "bytes=0-0"]), descriptor())
        #expect(try await collected(singleByte) == Data("a".utf8))
        #expect(singleByte.headers[.contentLength] == "1")
    }

    @Test("a multi-range request is ignored — full 200, not an error")
    func multiRangeIsIgnored() async throws {
        let response = serveContent(
            for: request(headers: [.range: "bytes=0-3, 10-13"]), descriptor())
        #expect(response.status == .ok)
        #expect(try await collected(response) == body)
    }

    @Test("malformed and foreign-unit Range headers are ignored")
    func malformedRangeIsIgnored() {
        for value in ["bytes=abc-def", "lines=1-2", "bytes=5-2", "bytes", "bytes=", "bytes=-"] {
            let response = serveContent(
                for: request(headers: [.range: value]), descriptor())
            #expect(response.status == .ok, "'\(value)' must be ignored, not an error")
        }
    }

    @Test("HEAD with a Range gets 206 and Content-Range — the GET's exact headers")
    func headWithRange() {
        // One framework answers HEAD+Range with a 200 carrying 206 headers.
        let response = serveContent(
            for: request(.head, headers: [.range: "bytes=0-3"]), descriptor())
        #expect(response.status == .partialContent)
        #expect(response.headers[.contentRange] == "bytes 0-3/26")
        #expect(response.headers[.contentLength] == "4")
    }

    @Test("a zero-length source is a 200 with Content-Length 0")
    func zeroLengthSource() async throws {
        let empty = ContentDescriptor(source: DataByteSource(Data()))
        let response = serveContent(for: request(), empty)
        #expect(response.status == .ok)
        #expect(response.headers[.contentLength] == "0")
        #expect(try await collected(response).isEmpty)

        // And any range against it is unsatisfiable.
        let ranged = serveContent(for: request(headers: [.range: "bytes=-5"]), empty)
        #expect(ranged.status == .rangeNotSatisfiable)
        #expect(ranged.headers[.contentRange] == "bytes */0")
    }
}

@Suite("serveContent — conditionals")
struct ServeContentConditionalTests {

    @Test("If-None-Match matches through a comma-separated list")
    func ifNoneMatchList() {
        // Multi-value revalidation is what browsers actually send; one
        // framework compares the whole raw header against one ETag and
        // never matches.
        let response = serveContent(
            for: request(headers: [.ifNoneMatch: #""v0", "v1", "v2""#]), descriptor())
        #expect(response.status == .notModified)
    }

    @Test("If-None-Match: * always matches")
    func ifNoneMatchStar() {
        let response = serveContent(
            for: request(headers: [.ifNoneMatch: "*"]), descriptor())
        #expect(response.status == .notModified)
    }

    @Test("weak comparison: W/\"v1\" revalidates \"v1\" and vice versa")
    func weakComparison() {
        let weakRequest = serveContent(
            for: request(headers: [.ifNoneMatch: #"W/"v1""#]), descriptor())
        #expect(weakRequest.status == .notModified)

        let weakStored = serveContent(
            for: request(headers: [.ifNoneMatch: #""v1""#]),
            descriptor(etag: EntityTag("v1", weak: true)))
        #expect(weakStored.status == .notModified)
    }

    @Test("an ETag containing a comma survives list parsing")
    func etagWithComma() {
        // Legal per the grammar, corrupted by split-on-comma parsers.
        let response = serveContent(
            for: request(headers: [.ifNoneMatch: #""alpha,beta", "v1""#]), descriptor())
        #expect(response.status == .notModified)
    }

    @Test("a non-matching If-None-Match serves the full body")
    func ifNoneMatchMiss() {
        let response = serveContent(
            for: request(headers: [.ifNoneMatch: #""other""#]), descriptor())
        #expect(response.status == .ok)
    }

    @Test("If-Modified-Since is honored — not just emitted and ignored")
    func ifModifiedSince() {
        // One framework sends Last-Modified and then never reads the
        // corresponding request header at all.
        let modified = Date(timeIntervalSince1970: 1_700_000_000)
        let notModifiedSince = serveContent(
            for: request(headers: [.ifModifiedSince: HTTPDate.format(modified)]),
            descriptor(modified: modified))
        #expect(notModifiedSince.status == .notModified)

        let changedSince = serveContent(
            for: request(headers: [
                .ifModifiedSince: HTTPDate.format(modified.addingTimeInterval(-60))
            ]),
            descriptor(modified: modified))
        #expect(changedSince.status == .ok)
    }

    @Test("If-None-Match wins over If-Modified-Since when both are present")
    func ifNoneMatchBeatsIfModifiedSince() {
        // RFC 9110 §13.1.3: a cache that has an ETag revalidates by it; the
        // date must not resurrect a 304 the ETag comparison rejected.
        let modified = Date(timeIntervalSince1970: 1_700_000_000)
        let response = serveContent(
            for: request(headers: [
                .ifNoneMatch: #""other""#,
                .ifModifiedSince: HTTPDate.format(modified),
            ]),
            descriptor(modified: modified))
        #expect(response.status == .ok)
    }

    @Test("a 304 keeps the validator and cache headers, and only those")
    func notModifiedHeaders() {
        let response = serveContent(
            for: request(headers: [.ifNoneMatch: #""v1""#]),
            descriptor(cacheControl: "public, max-age=60"))
        #expect(response.status == .notModified)
        #expect(response.headers[.eTag] == #""v1""#)
        #expect(response.headers[.cacheControl] == "public, max-age=60")
        #expect(response.headers[.lastModified] != nil)
        #expect(response.headers[.contentType] == nil, "a 304 has no representation to type")
        #expect(response.bodyData?.isEmpty == true)
    }

    @Test("If-Range with a matching strong ETag yields the range")
    func ifRangeStrongMatch() {
        let response = serveContent(
            for: request(headers: [.range: "bytes=0-3", .ifRange: #""v1""#]),
            descriptor(etag: EntityTag("v1")))
        #expect(response.status == .partialContent)
    }

    @Test("If-Range never matches a weak ETag — resumption demands certainty")
    func ifRangeRejectsWeak() {
        // A weak validator says "probably unchanged"; resuming a download on
        // "probably" is how silently corrupt files are assembled. One
        // framework has no If-Range handling at all, which is the same bug
        // with fewer steps.
        let response = serveContent(
            for: request(headers: [.range: "bytes=0-3", .ifRange: #""v1""#]),
            descriptor(etag: EntityTag("v1", weak: true)))
        #expect(response.status == .ok, "weak validator → full body, not a resumed range")
    }

    @Test("If-Range with a stale validator downgrades to the full body")
    func ifRangeMismatch() async throws {
        let response = serveContent(
            for: request(headers: [.range: "bytes=0-3", .ifRange: #""old""#]),
            descriptor(etag: EntityTag("v1")))
        #expect(response.status == .ok)
        #expect(try await response.collectedBody() == body)
    }

    @Test("If-Range accepts the exact Last-Modified date, and only exactly")
    func ifRangeDate() {
        let modified = Date(timeIntervalSince1970: 1_700_000_000)
        let exact = serveContent(
            for: request(headers: [
                .range: "bytes=0-3", .ifRange: HTTPDate.format(modified),
            ]),
            descriptor(modified: modified))
        #expect(exact.status == .partialContent)

        let stale = serveContent(
            for: request(headers: [
                .range: "bytes=0-3",
                .ifRange: HTTPDate.format(modified.addingTimeInterval(-1)),
            ]),
            descriptor(modified: modified))
        #expect(stale.status == .ok)
    }

    @Test("non-GET/HEAD methods get the representation with no conditional processing")
    func writeMethodsAreServedPlainly() {
        let response = serveContent(
            for: request(.post, headers: [.ifNoneMatch: #""v1""#, .range: "bytes=0-3"]),
            descriptor())
        #expect(response.status == .ok)
    }

    @Test("every 200 advertises Accept-Ranges and carries the validators")
    func advertisedHeaders() {
        let response = serveContent(for: request(), descriptor())
        #expect(response.headers[.acceptRanges] == "bytes")
        #expect(response.headers[.eTag] == #""v1""#)
        #expect(response.headers[.lastModified] != nil)
        #expect(response.headers[.contentLength] == "26")
        #expect(response.headers[.contentType] == "text/plain")
    }
}

@Suite("HTTP dates")
struct HTTPDateTests {

    @Test("IMF-fixdate formats and parses back exactly")
    func imfRoundTrip() {
        // The RFC's own example: Sun, 06 Nov 1994 08:49:37 GMT.
        let date = Date(timeIntervalSince1970: 784_111_777)
        let formatted = HTTPDate.format(date)
        #expect(formatted == "Sun, 06 Nov 1994 08:49:37 GMT")
        #expect(HTTPDate.parse(formatted) == date)
    }

    @Test("the two obsolete forms parse to the same instant")
    func obsoleteForms() {
        let expected = Date(timeIntervalSince1970: 784_111_777)
        #expect(HTTPDate.parse("Sunday, 06-Nov-94 08:49:37 GMT") == expected)
        #expect(HTTPDate.parse("Sun Nov  6 08:49:37 1994") == expected)
    }

    @Test("garbage does not parse")
    func garbage() {
        for value in ["", "yesterday", "Sun, 32 Nov 1994 08:49:37 GMT", "Sun, 06 Nov 1994 25:00:00 GMT"] {
            #expect(HTTPDate.parse(value) == nil, "'\(value)'")
        }
    }

    @Test("dates far from the epoch survive the round trip")
    func extremes() {
        for seconds: TimeInterval in [0, 1, 946_684_800, 4_102_444_800, 86_399] {
            let date = Date(timeIntervalSince1970: seconds)
            #expect(HTTPDate.parse(HTTPDate.format(date)) == date)
        }
    }
}
