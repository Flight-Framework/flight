import Foundation
import FlightWeb
import HTTPTypes
import Testing

// The RFC 7578 parser against the bodies browsers send and the bodies
// attackers send. The chunk-seam property test is the load-bearing one: a
// streaming parser's classic failure is a boundary straddling two reads.

private let boundary = "----FlightBoundary7MA4YWxk"

/// A wire-exact body: CRLF everywhere, closing delimiter included.
private func wireBody(preamble: String = "", epilogue: String = "", parts: [(headers: [String], body: String)]) -> Data {
    var text = preamble
    for part in parts {
        text += "--\(boundary)\r\n"
        for header in part.headers { text += header + "\r\n" }
        text += "\r\n" + part.body + "\r\n"
    }
    text += "--\(boundary)--" + epilogue
    return Data(text.utf8)
}

private func field(_ name: String, _ value: String) -> (headers: [String], body: String) {
    (["Content-Disposition: form-data; name=\"\(name)\""], value)
}

private func file(_ name: String, filename: String, type: String, _ body: String) -> (headers: [String], body: String) {
    (
        [
            "Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"",
            "Content-Type: \(type)",
        ], body
    )
}

/// Collects every part fully — the reference consumption.
private func collectAll(
    _ body: Data, limits: MultipartLimits = MultipartLimits(), chunkSplit: Int? = nil
) async throws -> [(name: String, filename: String?, type: String?, body: Data)] {
    let reader: MultipartReader
    if let split = chunkSplit {
        let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        continuation.yield(body.prefix(split))
        continuation.yield(body.dropFirst(split))
        continuation.finish()
        reader = MultipartReader(boundary: boundary, chunks: stream, limits: limits)
    } else {
        reader = MultipartReader(boundary: boundary, body: body, limits: limits)
    }
    var collected: [(String, String?, String?, Data)] = []
    for try await part in reader {
        collected.append(
            (part.name, part.filename, part.contentType?.essence, try await part.bytes()))
    }
    return collected
}

@Suite("multipart — parsing")
struct MultipartParsingTests {

    @Test("fields and files, mixed, parse with their headers")
    func mixedParts() async throws {
        let body = wireBody(parts: [
            field("title", "Q3 report"),
            file("doc", filename: "report.pdf", type: "application/pdf", "PDFBYTES"),
            field("notes", "second field"),
            file("image", filename: "chart.png", type: "image/png", "PNGBYTES"),
        ])
        let parts = try await collectAll(body)
        #expect(parts.count == 4)
        #expect(parts[0].name == "title")
        #expect(parts[0].filename == nil)
        #expect(parts[0].body == Data("Q3 report".utf8))
        #expect(parts[1].filename == "report.pdf")
        #expect(parts[1].type == "application/pdf")
        #expect(parts[3].body == Data("PNGBYTES".utf8))
    }

    @Test("THE seam test: every possible chunk split yields identical parts")
    func everyChunkSeam() async throws {
        // A body whose content includes near-boundary bytes, split into two
        // chunks at every offset. Any lookback off-by-one shows up here.
        let body = wireBody(parts: [
            field("a", "alpha--\r\nbeta"),
            file("f", filename: "x.bin", type: "application/octet-stream", "\r\n--almost\r\n-"),
        ])
        let reference = try await collectAll(body)
        for split in 0...body.count {
            let parts = try await collectAll(body, chunkSplit: split)
            #expect(parts.count == reference.count, "split \(split)")
            for (got, want) in zip(parts, reference) {
                #expect(got.body == want.body, "split \(split)")
                #expect(got.name == want.name, "split \(split)")
            }
        }
    }

    @Test("a boundary-lookalike inside a body line is data, not a delimiter")
    func boundaryLookalike() async throws {
        // `--boundary` NOT preceded by CRLF must never terminate a part.
        let sneaky = "text before --\(boundary) and after"
        let parts = try await collectAll(wireBody(parts: [field("a", sneaky)]))
        #expect(parts[0].body == Data(sneaky.utf8))
    }

    @Test("preamble and epilogue are ignored")
    func preambleAndEpilogue() async throws {
        let body = wireBody(
            preamble: "This is the preamble, ignored per RFC.\r\n",
            epilogue: "\r\ntrailing garbage",
            parts: [field("a", "1")])
        let parts = try await collectAll(body)
        #expect(parts.count == 1)
        #expect(parts[0].body == Data("1".utf8))
    }

    @Test("empty field and zero-length file are legal")
    func emptyBodies() async throws {
        let parts = try await collectAll(
            wireBody(parts: [
                field("empty", ""),
                file("f", filename: "empty.bin", type: "application/octet-stream", ""),
            ]))
        #expect(parts[0].body.isEmpty)
        #expect(parts[1].body.isEmpty)
        #expect(parts[1].filename == "empty.bin")
    }

    @Test("filenames are stripped to a safe basename")
    func filenameHardening() async throws {
        let parts = try await collectAll(
            wireBody(parts: [
                file("a", filename: "../../etc/cron.d/evil", type: "text/plain", "x"),
                // Wire-correct escaping: a literal backslash inside a
                // quoted-string arrives as \\ (Chrome escapes it so).
                file("b", filename: "C:\\\\Users\\\\victim\\\\run.exe", type: "text/plain", "x"),
                file("c", filename: "..", type: "text/plain", "x"),
                file("d", filename: "olé résumé.pdf", type: "text/plain", "x"),
            ]))
        #expect(parts[0].filename == "evil")
        #expect(parts[1].filename == "run.exe")
        // And the UNescaped spelling: quoted-pair consumption eats the
        // single backslashes before basename ever runs — documented, not
        // accidental. No path separator survives either way.
        let bare = try await collectAll(
            wireBody(parts: [
                file("e", filename: "C:\\Users\\victim\\run.exe", type: "text/plain", "x")
            ]))
        #expect(bare[0].filename == "C:Usersvictimrun.exe")
        #expect(parts[2].filename == "_")
        #expect(parts[3].filename == "olé résumé.pdf", "UTF-8 names pass through")
    }

    @Test("missing close delimiter is truncated, never a complete-looking upload")
    func truncatedBody() async throws {
        var body = wireBody(parts: [field("a", "1"), field("b", "2")])
        body.removeLast("--\(boundary)--".count)
        await #expect(throws: MultipartError.truncated) {
            _ = try await collectAll(body)
        }
    }

    @Test("LF-only line endings are malformed, not guessed at")
    func lfOnlyRefused() async throws {
        let lf = Data(
            "--\(boundary)\nContent-Disposition: form-data; name=\"a\"\n\n1\n--\(boundary)--"
                .utf8)
        await #expect(throws: MultipartError.self) {
            _ = try await collectAll(lf)
        }
    }

    @Test("a part without a Content-Disposition name fails the parse")
    func missingDisposition() async throws {
        let body = wireBody(parts: [(headers: ["Content-Type: text/plain"], body: "x")])
        await #expect(throws: MultipartError.self) {
            _ = try await collectAll(body)
        }
    }

    @Test("transport padding after the boundary is tolerated")
    func transportPadding() async throws {
        let body = Data(
            ("--\(boundary)  \t\r\n"
                + "Content-Disposition: form-data; name=\"a\"\r\n\r\n"
                + "1\r\n"
                + "--\(boundary)--").utf8)
        let parts = try await collectAll(body)
        #expect(parts[0].body == Data("1".utf8))
    }
}

@Suite("multipart — limits and contract")
struct MultipartLimitTests {

    @Test("the part-count bomb hits its named cap")
    func partBomb() async throws {
        var limits = MultipartLimits()
        limits.maxParts = 8
        let body = wireBody(parts: (0..<20).map { field("f\($0)", "x") })
        await #expect(throws: MultipartError.tooManyParts(limit: 8)) {
            _ = try await collectAll(body, limits: limits)
        }
    }

    @Test("the header bomb hits its named caps — bytes and count")
    func headerBombs() async throws {
        var limits = MultipartLimits()
        limits.maxHeaderBytesPerPart = 128
        let bigHeader = "X-Padding: " + String(repeating: "a", count: 500)
        await #expect(throws: MultipartError.headersTooLarge(limit: 128)) {
            _ = try await collectAll(
                wireBody(parts: [
                    (
                        headers: [
                            "Content-Disposition: form-data; name=\"a\"", bigHeader,
                        ], body: "x"
                    )
                ]),
                limits: limits)
        }

        var countLimits = MultipartLimits()
        countLimits.maxHeadersPerPart = 3
        let manyHeaders = (0..<10).map { "X-H\($0): v" }
        await #expect(throws: MultipartError.tooManyHeaders(limit: 3)) {
            _ = try await collectAll(
                wireBody(parts: [
                    (
                        headers: ["Content-Disposition: form-data; name=\"a\""] + manyHeaders,
                        body: "x"
                    )
                ]),
                limits: countLimits)
        }
    }

    @Test("text() refuses a body over its cap instead of allocating it")
    func collectCap() async throws {
        var limits = MultipartLimits()
        limits.maxBufferedPartBytes = 16
        let reader = MultipartReader(
            boundary: boundary,
            body: wireBody(parts: [field("big", String(repeating: "z", count: 1_000))]),
            limits: limits)
        for try await part in reader {
            await #expect(throws: MultipartError.partTooLarge(name: "big", limit: 16)) {
                _ = try await part.text()
            }
            break
        }
    }

    @Test("an unread part is drained on advance; the next part is intact")
    func autoDrain() async throws {
        let reader = MultipartReader(
            boundary: boundary,
            body: wireBody(parts: [
                field("skipped", String(repeating: "x", count: 10_000)),
                field("wanted", "value"),
            ]))
        var names: [String] = []
        var lastBody: Data?
        for try await part in reader {
            names.append(part.name)
            if part.name == "wanted" { lastBody = try await part.bytes() }
            // "skipped" deliberately never read.
        }
        #expect(names == ["skipped", "wanted"])
        #expect(lastBody == Data("value".utf8))
    }

    @Test("reading a stale part's body is a structured error, not a deadlock")
    func staleBodyAccess() async throws {
        let reader = MultipartReader(
            boundary: boundary,
            body: wireBody(parts: [field("first", "1"), field("second", "2")]))
        var iterator = reader.makeAsyncIterator()
        let first = try #require(try await iterator.next())
        _ = try await iterator.next()  // advance past `first`
        await #expect(throws: MultipartError.partAlreadyConsumed) {
            _ = try await first.bytes()
        }
    }

    @Test("request.multipart(): wrong type is a 415, missing boundary a 400")
    func requestEntry() throws {
        let json = Request(
            method: .post, path: "/u", headers: [.contentType: "application/json"],
            body: Data("{}".utf8))
        #expect(throws: UnsupportedMediaTypeError.self) {
            _ = try json.multipart()
        }

        let noBoundary = Request(
            method: .post, path: "/u", headers: [.contentType: "multipart/form-data"],
            body: Data())
        #expect(throws: MultipartError.self) {
            _ = try noBoundary.multipart()
        }

        let good = Request(
            method: .post, path: "/u",
            headers: [.contentType: "multipart/form-data; boundary=\(boundary)"],
            body: wireBody(parts: [field("a", "1")]))
        _ = try good.multipart()
    }
}

extension MultipartError: Equatable {
    public static func == (lhs: MultipartError, rhs: MultipartError) -> Bool {
        lhs.description == rhs.description
    }
}
