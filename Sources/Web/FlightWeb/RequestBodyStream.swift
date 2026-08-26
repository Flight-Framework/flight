import Foundation
import HTTPTypes

/// A request body delivered as it arrives, instead of buffered whole — what
/// an upload route takes when the body should never all be in memory.
///
/// A handler opts in by taking it as its `body:` parameter; the macro
/// records the route as streaming-bodied in the route table, and the
/// transport — which asks the table before collecting, exactly as it
/// already asks `acceptsUpgrade` — hands the live byte sequence through
/// rather than buffering. Every other route keeps the buffered
/// `Request.body` unchanged.
///
/// ```swift
/// @PostMapping("/import", maxBodyBytes: 2 << 30)
/// func importArchive(_ context: RequestContext, body: RequestBodyStream) async throws -> Response {
///     for try await chunk in body.chunks { try await ingest(chunk) }
///     ...
/// }
/// ```
///
/// Deliberately **not** `Decodable`: a stream is not a value, and making it
/// one would route it into the negotiated-decode path whose whole premise
/// is a buffered body.
public struct RequestBodyStream: Sendable {
    /// The client's `Content-Length`, when it sent one. Chunked transfer
    /// encoding has none — treat this as a progress hint, never a promise.
    public let expectedBytes: Int64?

    /// The body, in arrival order. Single-consumer. Throws mid-iteration
    /// if the client disconnects or the route's body cap is exceeded —
    /// a partial upload must fail loudly, never truncate silently.
    public let chunks: AsyncThrowingStream<Data, any Error>

    public init(expectedBytes: Int64?, chunks: AsyncThrowingStream<Data, any Error>) {
        self.expectedBytes = expectedBytes
        self.chunks = chunks
    }
}

/// A streaming route's body cap was exceeded mid-stream. The handler's
/// iteration throws this; rendered as 413.
public struct BodyStreamLimitError: HTTPErrorRepresentable, Sendable {
    public let httpStatus: HTTPResponse.Status = .contentTooLarge
    public let httpMessage: String

    public init(limit: Int) {
        self.httpMessage = "Content Too Large: request body exceeds \(limit) bytes"
    }
}

/// The `body: RequestBodyStream` handler parameter — resolved by overload
/// over the generic `Decodable` form at the same macro-emitted call site.
/// Present only when the transport actually streamed this request; a
/// buffered request reaching a streaming handler is a wiring defect
/// (a hand-built dispatch that ignored the route's `bodyMode`), surfaced
/// as a 500 with the log carrying the explanation.
public func decodeRequestBody(
    _ type: RequestBodyStream.Type = RequestBodyStream.self,
    from context: RequestContext
) throws -> RequestBodyStream {
    guard let stream = context.request.bodyStream else {
        throw HTTPError(
            .internalServerError,
            "this route's body was buffered by the transport despite its streaming body mode")
    }
    return stream
}

extension Request {
    /// The live body stream, present exactly when the transport streamed
    /// this request instead of buffering it (`bodyMode == .streaming` on
    /// the matched route). `body` is empty in that case.
    public var bodyStream: RequestBodyStream? {
        get { _bodyStream?.stream }
        set { _bodyStream = newValue.map(BodyStreamBox.init) }
    }
}

/// Reference box so `Request` (a value type copied freely through the
/// pipeline) carries the single-consumer stream without each copy pretending
/// to own an independent one.
final class BodyStreamBox: Sendable {
    let stream: RequestBodyStream
    init(stream: RequestBodyStream) { self.stream = stream }
}
