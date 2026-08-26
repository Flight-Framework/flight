import Foundation
import HTTPTypes

/// `multipart/form-data` (RFC 7578), parsed as a stream: the browser's file
/// -upload wire format, read part by part without ever holding a part's
/// body in memory unless the caller asks for it collected.
///
/// The reader is **pull-based all the way down** — nothing is parsed until
/// the consumer asks, and a part's body flows chunk-by-chunk from whatever
/// feeds the parser. That is what makes the consumption contract cheap to
/// state and safe to enforce:
///
/// - Parts arrive strictly in wire order.
/// - Advancing to the next part **drains and discards** whatever of the
///   current part's body was not read (Go's model). Reading a previous
///   part's body after advancing is a structured error, never a deadlock.
/// - A part's body is single-consumer.
///
/// Wire strictness, decided: CRLF line endings only (every browser sends
/// them; an LF-only body is malformed, not leniently guessed at); the
/// close delimiter is required — EOF without it is a `truncated` error,
/// because a cut-off upload must never look complete; the preamble and
/// epilogue are ignored per RFC; nested `multipart/mixed` is treated as an
/// opaque part body (an obsolete browser feature, not recursed into).
///
/// Limits are explicit and each violation is a named error — multipart is
/// an attacker-shaped format, and Go needed a CVE (2023-24536) before its
/// parser grew part and header caps. Ours start with them.
public struct MultipartReader: AsyncSequence, Sendable {
    public typealias Element = MultipartPart

    let engine: MultipartEngine

    /// Parses `body` (the already-buffered request body) against `boundary`.
    public init(boundary: String, body: Data, limits: MultipartLimits = MultipartLimits()) {
        let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        continuation.yield(body)
        continuation.finish()
        self.init(boundary: boundary, chunks: stream, limits: limits)
    }

    /// Parses a live chunk stream — what a streaming-bodied route feeds.
    public init(
        boundary: String,
        chunks: AsyncThrowingStream<Data, any Error>,
        limits: MultipartLimits = MultipartLimits()
    ) {
        self.engine = MultipartEngine(boundary: boundary, limits: limits, chunks: chunks)
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(engine: engine)
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        let engine: MultipartEngine

        public mutating func next() async throws -> MultipartPart? {
            guard let info = try await engine.nextPart() else { return nil }
            let engine = self.engine
            let index = info.index
            return MultipartPart(
                info: info,
                body: AsyncThrowingStream(unfolding: {
                    try await engine.nextBodyChunk(ofPart: index)
                }),
                limits: engine.limits)
        }
    }
}

public struct MultipartLimits: Sendable {
    /// Go capped at 1000 after CVE-2023-24536; a real form has dozens.
    public var maxParts = 256
    public var maxHeaderBytesPerPart = 16 << 10
    public var maxHeadersPerPart = 32
    /// The cap for the `text()`/`bytes()` conveniences — NOT for streamed
    /// bodies, which are unbounded by construction and bounded by the
    /// route's body cap instead.
    public var maxBufferedPartBytes = 1 << 20

    public init() {}
}

/// One part: its parsed headers, and its body as a chunk stream.
public struct MultipartPart: Sendable {
    /// `Content-Disposition`'s `name` — required by RFC 7578; a part
    /// without one fails the whole parse as malformed.
    public let name: String
    /// `Content-Disposition`'s `filename`, if the part is a file. Path
    /// separators are stripped to the basename: the value is attacker-
    /// controlled and destined for filesystems.
    public let filename: String?
    /// The part's own `Content-Type` header, when present.
    public let contentType: MediaType?
    /// Every header of the part, as sent.
    public let headers: [(name: String, value: String)]

    /// The body, chunk by chunk. Single-consumer; finishes at the part
    /// boundary. Unread remainder is discarded when the part sequence
    /// advances.
    public let body: AsyncThrowingStream<Data, any Error>

    let limits: MultipartLimits

    init(info: MultipartPartInfo, body: AsyncThrowingStream<Data, any Error>, limits: MultipartLimits) {
        self.name = info.name
        self.filename = info.filename
        self.contentType = info.contentType
        self.headers = info.headers
        self.body = body
        self.limits = limits
    }

    /// Collects the body as UTF-8 text — the form-field case. Bounded by
    /// `maxBytes` (default: the reader's `maxBufferedPartBytes`); a larger
    /// body is a 413, not an allocation.
    public func text(maxBytes: Int? = nil) async throws -> String {
        let data = try await bytes(maxBytes: maxBytes)
        guard let text = String(data: data, encoding: .utf8) else {
            throw MultipartError.malformed("part '\(name)' is not valid UTF-8")
        }
        return text
    }

    /// Collects the body as bytes, bounded like `text(maxBytes:)`.
    public func bytes(maxBytes: Int? = nil) async throws -> Data {
        let cap = maxBytes ?? limits.maxBufferedPartBytes
        var collected = Data()
        for try await chunk in body {
            collected.append(chunk)
            guard collected.count <= cap else {
                throw MultipartError.partTooLarge(name: name, limit: cap)
            }
        }
        return collected
    }

    /// Reads the body to its end and discards it.
    public func discard() async throws {
        for try await _ in body {}
    }
}

public enum MultipartError: Error, Sendable, HTTPErrorRepresentable, CustomStringConvertible {
    /// The bytes do not parse as multipart against the declared boundary.
    case malformed(String)
    /// EOF before the close delimiter: a cut-off upload, refused rather
    /// than served as if complete.
    case truncated
    case tooManyParts(limit: Int)
    case headersTooLarge(limit: Int)
    case tooManyHeaders(limit: Int)
    case partTooLarge(name: String, limit: Int)
    /// A part's body was read after the sequence advanced past it — the
    /// consumption contract, enforced as an error instead of a deadlock.
    case partAlreadyConsumed

    public var httpStatus: HTTPResponse.Status {
        switch self {
        case .partTooLarge: return .contentTooLarge
        case .partAlreadyConsumed: return .internalServerError
        default: return .badRequest
        }
    }

    public var httpMessage: String {
        switch self {
        case .partAlreadyConsumed: return "Internal Server Error"
        case .partTooLarge(let name, let limit):
            return "Multipart part '\(name)' exceeds the \(limit)-byte limit"
        case .malformed(let reason): return "Malformed multipart body: \(reason)"
        case .truncated: return "Malformed multipart body: ended before the closing boundary"
        case .tooManyParts(let limit): return "Multipart body exceeds \(limit) parts"
        case .headersTooLarge(let limit):
            return "Multipart part headers exceed \(limit) bytes"
        case .tooManyHeaders(let limit): return "Multipart part exceeds \(limit) headers"
        }
    }

    public var description: String { httpMessage }
}

struct MultipartPartInfo: Sendable {
    let index: Int
    let name: String
    let filename: String?
    let contentType: MediaType?
    let headers: [(name: String, value: String)]
}

// MARK: - The engine

/// The RFC 7578 state machine. An actor because part iterators and the
/// parts sequence share it; the consumption contract means exactly one of
/// them is active at a time, and index checks turn violations into errors.
actor MultipartEngine {
    let limits: MultipartLimits
    private let delimiter: Data  // CRLF "--" boundary
    private let feeder: FeederBox
    /// Reentrancy tripwire: the contract is single-consumer, and the actor
    /// suspends at `fill` — a second task interleaving there would race the
    /// iterator. Contract violations become an error, never UB.
    private var filling = false

    private enum State {
        case preamble
        case headers
        case body
        /// Delimiter consumed; deciding between a next part and the close.
        case afterDelimiter
        case finished
        case failed(MultipartError)
    }

    private var state: State = .preamble
    private var buffer: Data
    private var reachedEOF = false
    private var partsSeen = 0
    /// The index of the part whose body is (or was) current; 0 = none yet.
    private var currentPartIndex = 0
    private var currentPartEnded = true

    init(boundary: String, limits: MultipartLimits, chunks: AsyncThrowingStream<Data, any Error>) {
        self.limits = limits
        self.feeder = FeederBox(chunks)
        self.delimiter = Data("\r\n--\(boundary)".utf8)
        // The virtual leading CRLF: the first delimiter on the wire is
        // `--boundary` with nothing before it, every later one is
        // `CRLF--boundary`. Seeding the buffer makes them one pattern.
        self.buffer = Data("\r\n".utf8)
    }

    // MARK: Consumer surface

    /// Advances to the next part: drains the current part's unread body,
    /// then parses through the boundary. `nil` after the close delimiter.
    func nextPart() async throws -> MultipartPartInfo? {
        if !currentPartEnded {
            while try await nextBodyChunk(ofPart: currentPartIndex) != nil {}
        }
        while true {
            switch state {
            case .failed(let error): throw error
            case .finished: return nil
            case .preamble:
                guard try await consumeThroughDelimiter(discarding: true) else { continue }
                state = .afterDelimiter
            case .afterDelimiter:
                guard let isClose = try await resolveAfterDelimiter() else { continue }
                if isClose {
                    state = .finished
                    return nil
                }
                state = .headers
            case .headers:
                guard let info = try await parseHeaders() else { continue }
                state = .body
                currentPartIndex = info.index
                currentPartEnded = false
                return info
            case .body:
                // Unreachable: entering nextPart with an open body drained
                // it above. Kept total.
                _ = try await nextBodyChunk(ofPart: currentPartIndex)
            }
        }
    }

    /// The next chunk of part `index`'s body; `nil` at its boundary.
    func nextBodyChunk(ofPart index: Int) async throws -> Data? {
        guard index == currentPartIndex else {
            throw MultipartError.partAlreadyConsumed
        }
        if currentPartEnded { return nil }
        while true {
            if case .failed(let error) = state { throw error }
            guard case .body = state else {
                currentPartEnded = true
                return nil
            }
            // A delimiter wholly in the buffer ends the part.
            if let found = buffer.range(of: delimiter) {
                let chunk = buffer.prefix(upTo: found.lowerBound)
                buffer.removeSubrange(buffer.startIndex..<found.upperBound)
                state = .afterDelimiter
                currentPartEnded = true
                return chunk.isEmpty ? nil : Data(chunk)
            }
            // No delimiter: everything except a possible delimiter prefix
            // at the tail is safely body — emit it, keep the lookback.
            let lookback = delimiter.count - 1
            if buffer.count > lookback {
                let emit = buffer.prefix(buffer.count - lookback)
                buffer.removeFirst(buffer.count - lookback)
                if !emit.isEmpty { return Data(emit) }
            }
            guard try await fill() else {
                fail(.truncated)
                continue
            }
        }
    }

    // MARK: Machine steps

    /// True once the delimiter has been consumed (bytes before it dropped);
    /// false means "pulled more input, go around".
    private func consumeThroughDelimiter(discarding: Bool) async throws -> Bool {
        if let found = buffer.range(of: delimiter) {
            buffer.removeSubrange(buffer.startIndex..<found.upperBound)
            return true
        }
        // Keep only what could still start a delimiter.
        let lookback = delimiter.count - 1
        if discarding, buffer.count > lookback {
            buffer.removeFirst(buffer.count - lookback)
        }
        guard try await fill() else {
            fail(.malformed("no boundary found"))
            return false
        }
        return false
    }

    /// After a delimiter: `--` closes; optional transport padding then CRLF
    /// opens the next part. `nil` means "need more input".
    private func resolveAfterDelimiter() async throws -> Bool? {
        // Longest thing we must see through: padding + CRLF; scan modestly.
        while true {
            if buffer.count >= 2, buffer.starts(with: Data("--".utf8)) {
                return true
            }
            var index = buffer.startIndex
            while index < buffer.endIndex,
                buffer[index] == UInt8(ascii: " ") || buffer[index] == UInt8(ascii: "\t")
            {
                index = buffer.index(after: index)
            }
            if index < buffer.endIndex {
                if buffer[index] == UInt8(ascii: "\r") {
                    guard buffer.index(after: index) < buffer.endIndex else {
                        guard try await fill() else {
                            fail(.truncated)
                            return nil
                        }
                        continue
                    }
                    guard buffer[buffer.index(after: index)] == UInt8(ascii: "\n") else {
                        fail(.malformed("boundary line not terminated by CRLF"))
                        return nil
                    }
                    buffer.removeSubrange(buffer.startIndex...buffer.index(after: index))
                    return false
                }
                if buffer[index] != UInt8(ascii: "-") {
                    fail(.malformed("unexpected byte after boundary"))
                    return nil
                }
                // A lone "-" so far: fall through to read more.
            }
            guard try await fill() else {
                fail(.truncated)
                return nil
            }
        }
    }

    private func parseHeaders() async throws -> MultipartPartInfo? {
        let terminator = Data("\r\n\r\n".utf8)
        guard let end = buffer.range(of: terminator) else {
            guard buffer.count <= limits.maxHeaderBytesPerPart else {
                fail(.headersTooLarge(limit: limits.maxHeaderBytesPerPart))
                return nil
            }
            guard try await fill() else {
                fail(.truncated)
                return nil
            }
            return nil
        }
        let block = buffer.prefix(upTo: end.lowerBound)
        guard block.count <= limits.maxHeaderBytesPerPart else {
            fail(.headersTooLarge(limit: limits.maxHeaderBytesPerPart))
            return nil
        }
        buffer.removeSubrange(buffer.startIndex..<end.upperBound)

        partsSeen += 1
        guard partsSeen <= limits.maxParts else {
            fail(.tooManyParts(limit: limits.maxParts))
            return nil
        }

        guard let text = String(data: Data(block), encoding: .utf8) else {
            fail(.malformed("part headers are not valid UTF-8"))
            return nil
        }
        var headers: [(name: String, value: String)] = []
        for line in text.components(separatedBy: "\r\n") where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else {
                fail(.malformed("part header line has no colon"))
                return nil
            }
            headers.append(
                (
                    name: String(line[..<colon]),
                    value: line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                ))
        }
        guard headers.count <= limits.maxHeadersPerPart else {
            fail(.tooManyHeaders(limit: limits.maxHeadersPerPart))
            return nil
        }

        guard
            let dispositionValue = headers.first(where: {
                $0.name.lowercased() == "content-disposition"
            })?.value,
            let disposition = ContentDisposition(parsing: dispositionValue),
            let name = disposition.name
        else {
            fail(.malformed("part has no Content-Disposition name"))
            return nil
        }
        let contentType = headers.first { $0.name.lowercased() == "content-type" }
            .flatMap { MediaType(parsing: $0.value) }

        return MultipartPartInfo(
            index: partsSeen,
            name: name,
            filename: disposition.filename.map(Self.basename),
            contentType: contentType,
            headers: headers)
    }

    /// Strips directory components: the filename is attacker-controlled
    /// and destined for filesystems; `../../etc/cron.d/x` arrives as `x`.
    private static func basename(_ filename: String) -> String {
        let base = filename.split(separator: "/").last.map {
            String($0.split(separator: "\\").last ?? $0)
        } ?? ""
        // "." and ".." survive basename-stripping and are still hostile to
        // any consumer joining paths.
        return base == "." || base == ".." ? "_" : base
    }

    /// Pulls one chunk into the buffer; false at EOF.
    private func fill() async throws -> Bool {
        if reachedEOF { return false }
        guard !filling else {
            throw MultipartError.malformed("concurrent multipart consumption")
        }
        filling = true
        defer { filling = false }
        guard let chunk = try await feeder.next() else {
            reachedEOF = true
            return false
        }
        buffer.append(chunk)
        return true
    }

    private func fail(_ error: MultipartError) {
        state = .failed(error)
    }
}

/// Holds the feeder iterator outside actor storage: `next()` is mutating
/// and async, which Swift refuses on actor-isolated properties. Access is
/// serialized by the engine (actor execution plus the `filling` tripwire),
/// which is what the `@unchecked` attests.
final class FeederBox: @unchecked Sendable {
    private var iterator: AsyncThrowingStream<Data, any Error>.AsyncIterator

    init(_ chunks: AsyncThrowingStream<Data, any Error>) {
        self.iterator = chunks.makeAsyncIterator()
    }

    func next() async throws -> Data? {
        try await iterator.next()
    }
}

/// `Content-Disposition: form-data; name="a"; filename="b.png"` — same
/// parameter grammar as a media type, without the slashed type.
struct ContentDisposition {
    let kind: String
    let name: String?
    let filename: String?

    init?(parsing value: String) {
        // Reuse MediaType's parameter machinery by prefixing a synthetic
        // type: `form-data; a=b` parses as `x/form-data; a=b`. (A slash
        // inside a quoted filename is fine — the split is on the first.)
        guard let media = MediaType(parsing: "x/" + value) else {
            return nil
        }
        self.kind = media.subtype
        self.name = media.parameter("name")
        self.filename = media.parameter("filename")
    }
}

extension Request {
    /// The request body as multipart parts. Requires
    /// `Content-Type: multipart/form-data` with a `boundary` parameter —
    /// anything else is a 415, a missing boundary a 400.
    ///
    /// Works with either body shape: a streaming-bodied route feeds the
    /// live chunk stream; an ordinary buffered route feeds `body`.
    public func multipart(limits: MultipartLimits = MultipartLimits()) throws -> MultipartReader {
        guard let raw = headers[.contentType], let media = MediaType(parsing: raw),
            media.essence == "multipart/form-data"
        else {
            throw UnsupportedMediaTypeError(
                received: headers[.contentType] ?? "(no Content-Type)",
                accepted: ["multipart/form-data"])
        }
        guard let boundary = media.parameter("boundary"), !boundary.isEmpty,
            boundary.utf8.count <= 70, !boundary.contains("\r"), !boundary.contains("\n")
        else {
            throw MultipartError.malformed("missing or invalid boundary parameter")
        }
        if let stream = bodyStream {
            return MultipartReader(boundary: boundary, chunks: stream.chunks, limits: limits)
        }
        return MultipartReader(boundary: boundary, body: body, limits: limits)
    }
}
