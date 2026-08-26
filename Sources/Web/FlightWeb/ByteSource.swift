import Foundation

/// A sized, randomly-accessible source of bytes — a file, a database blob,
/// an object-store item, a generated document.
///
/// This is the seam that keeps HTTP file semantics (`serveContent(for:_:)`)
/// separate from where bytes live, the decomposition Go's `ServeContent`
/// proved out: the conditional-request and range state machine is a function
/// over *any* sized byte source, so one tested implementation serves a file
/// on disk, a `bytea` column, and an in-memory render identically. Neither
/// of the ecosystem's file middlewares has this split — their range logic is
/// welded to the filesystem and unusable for anything else.
///
/// `count` is fixed at creation: a source represents a snapshot-sized value,
/// which is what `Content-Length`, `Content-Range` math, and cache
/// validators all assume. A backing store that changes size after the source
/// was created must surface that as an error from `chunks` (see
/// ``ByteSourceError/truncated(expected:delivered:)``), never as silently
/// different bytes under unchanged headers.
public protocol ByteSource: Sendable {
    /// Total size in bytes. Zero is legal (an empty file is still a 200 with
    /// `Content-Length: 0`).
    var count: Int64 { get }

    /// Streams `range` (half-open, within `0..<count`) in chunks of at most
    /// `chunkSize` bytes.
    ///
    /// Half-open, deliberately: HTTP's wire format for ranges is inclusive,
    /// but an inclusive `ClosedRange` cannot represent the empty range a
    /// zero-length file needs. The wire conversion happens exactly once, in
    /// `serveContent` — everything internal stays half-open.
    ///
    /// Implementations must respect task cancellation (a client that
    /// disconnects mid-download cancels the transport's write loop) and must
    /// finish or throw — never hang — when the backing store disappears.
    func chunks(in range: Range<Int64>, chunkSize: Int) -> AsyncThrowingStream<Data, any Error>
}

public enum ByteSourceError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The path exists but is not a regular file (a directory, a socket…).
    case notAFile(String)
    /// The backing store ended before the promised byte count — a file
    /// truncated after this source was opened. Thrown rather than silently
    /// delivering a short body, because the response's `Content-Length` has
    /// already been sent: a loud broken transfer beats a quietly wrong one.
    case truncated(expected: Int64, delivered: Int64)
    /// A system call failed. `operation` names which; `code` is errno.
    case io(operation: String, code: Int32)

    public var description: String {
        switch self {
        case .notAFile(let path):
            return "'\(path)' is not a regular file."
        case .truncated(let expected, let delivered):
            return
                "byte source ended after \(delivered) of \(expected) bytes — the backing store shrank after it was opened."
        case .io(let operation, let code):
            return "\(operation) failed: \(String(cString: strerror(code))) (errno \(code))"
        }
    }
}

/// An in-memory `ByteSource`. What a database blob or a generated document
/// uses, and what lets `serveContent`'s semantics be tested without a disk.
public struct DataByteSource: ByteSource {
    public let data: Data
    public var count: Int64 { Int64(data.count) }

    public init(_ data: Data) {
        self.data = data
    }

    public func chunks(in range: Range<Int64>, chunkSize: Int) -> AsyncThrowingStream<Data, any Error> {
        precondition(
            range.lowerBound >= 0 && range.upperBound <= count,
            "range \(range) outside 0..<\(count)")
        precondition(chunkSize > 0, "chunkSize must be positive")
        let data = self.data
        return AsyncThrowingStream { continuation in
            var offset = Int(range.lowerBound)
            let end = Int(range.upperBound)
            while offset < end {
                let sliceEnd = min(offset + chunkSize, end)
                // Re-based: a Data slice keeps its parent's indices, and
                // handing those out is a classic off-by-parent bug factory.
                continuation.yield(Data(data[data.startIndex + offset..<data.startIndex + sliceEnd]))
                offset = sliceEnd
            }
            continuation.finish()
        }
    }
}
