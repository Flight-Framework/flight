import Foundation
import HTTPTypes

/// One upload in progress: how much of it has durably landed, and what the
/// client said it would be.
public struct UploadInfo: Sendable, Codable, Equatable {
    public let id: String
    /// Bytes that have **durably** landed — fsynced and recorded. Never an
    /// optimistic count: this is the number a resuming client is told to
    /// continue from, so anything not survivable by a crash must not be in
    /// it.
    public var offset: Int64
    /// The final size the client declared at creation. Optional because
    /// deferred-length uploads exist in the protocol; this implementation
    /// requires it (see ``ResumableUploadError/deferredLengthUnsupported``).
    public var length: Int64?
    /// The client's `Upload-Metadata`, decoded from its base64 pairs and
    /// stored verbatim — filename, filetype, whatever the client chose. The
    /// server ascribes no meaning to it.
    public var metadata: [String: Data]
    public var expires: Date?
    public var isComplete: Bool

    public init(
        id: String, offset: Int64 = 0, length: Int64?, metadata: [String: Data] = [:],
        expires: Date? = nil, isComplete: Bool = false
    ) {
        self.id = id
        self.offset = offset
        self.length = length
        self.metadata = metadata
        self.expires = expires
        self.isComplete = isComplete
    }
}

/// Where the bytes of a resumable upload live.
///
/// The two rules an implementation must honor, because the whole
/// resumability contract rests on them and neither is checkable by the
/// protocol layer above:
///
/// 1. **`append` returns only durable offsets.** The number it returns is
///    what a resuming client will be told to continue from, so bytes
///    counted in it must survive a power cut. A store that returns an
///    optimistic count converts a crash into silent corruption: the client
///    resumes past bytes that were never written.
/// 2. **`append` verifies and advances the offset atomically, per id.** A
///    retried append at a stale offset must be refused
///    (``ResumableUploadError/offsetMismatch(current:)``), never applied
///    twice — that refusal is exactly what makes a flaky connection safe.
///    Concurrent appends to one id are refused
///    (``ResumableUploadError/uploadBusy``) rather than interleaved.
public protocol UploadStore: Sendable {
    func create(_ info: UploadInfo) async throws
    /// `nil` when the id is unknown (or was swept).
    func info(_ id: String) async throws -> UploadInfo?
    /// Appends `chunks` starting at `expectedOffset`, returning the new
    /// durable offset. See the protocol's two rules.
    func append(
        _ id: String, expectedOffset: Int64, chunks: AsyncThrowingStream<Data, any Error>
    ) async throws -> Int64
    func remove(_ id: String) async throws
    /// Removes uploads whose expiry has passed; returns how many. Called by
    /// whatever the application schedules — the mount does not sweep on its
    /// own, because how often to sweep is a deployment decision.
    func sweepExpired(now: Date) async throws -> Int
    /// The finished bytes, for serving a completed upload back.
    func readable(_ id: String) async throws -> any ByteSource
}

public enum ResumableUploadError: Error, Sendable, HTTPErrorRepresentable, Equatable {
    /// The client's `Upload-Offset` is not where the upload actually is.
    /// Carries the real offset so the client can seek and retry — the
    /// single most important error in the protocol.
    case offsetMismatch(current: Int64)
    /// Another append to this id is in flight.
    case uploadBusy
    case notFound
    case expired
    /// The declared length exceeds the mount's `maxSize`.
    case tooLarge(limit: Int64)
    /// The body would push the upload past its declared length.
    case exceedsDeclaredLength(length: Int64)
    case deferredLengthUnsupported
    case alreadyComplete
    case malformed(String)

    public var httpStatus: HTTPResponse.Status {
        switch self {
        // 409 Conflict is what tus 1.0 §Core specifies for an offset that
        // does not match; the response carries the current one.
        case .offsetMismatch: return .conflict
        case .uploadBusy: return HTTPResponse.Status(code: 423)  // Locked
        case .notFound: return .notFound
        case .expired: return .gone
        case .tooLarge, .exceedsDeclaredLength: return .contentTooLarge
        case .deferredLengthUnsupported, .malformed: return .badRequest
        case .alreadyComplete: return .conflict
        }
    }

    public var httpMessage: String {
        switch self {
        case .offsetMismatch(let current):
            return "Upload-Offset does not match; the upload is at \(current)"
        case .uploadBusy: return "Another append to this upload is in progress"
        case .notFound: return "No such upload"
        case .expired: return "This upload has expired"
        case .tooLarge(let limit): return "Upload exceeds the \(limit)-byte maximum"
        case .exceedsDeclaredLength(let length):
            return "Body would exceed the declared Upload-Length of \(length)"
        case .deferredLengthUnsupported:
            return "Upload-Defer-Length is not supported; send Upload-Length at creation"
        case .alreadyComplete: return "This upload is already complete"
        case .malformed(let reason): return "Malformed upload request: \(reason)"
        }
    }
}
