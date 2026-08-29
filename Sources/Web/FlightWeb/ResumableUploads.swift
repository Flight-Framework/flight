import FlightCore
import Foundation
import HTTPTypes

/// Resumable uploads over the **tus 1.0** protocol: a client uploads a
/// large file in appends, and a connection that dies mid-transfer costs
/// only the bytes since the last durability point rather than the whole
/// upload.
///
/// **Why tus 1.0 and not the IETF draft**, as of August 2026: the IETF
/// resumable-upload draft is at revision -12 / interop version 9, and no
/// shipped client anywhere speaks past interop 6 — Apple's URLSession tops
/// out there and only on Darwin, browsers have nothing native, curl has
/// nothing. Meanwhile every JavaScript upload stack in use (Uppy,
/// tus-js-client) and the platforms behind them (Supabase, Cloudflare
/// Stream, Vimeo) speak tus 1.0, and tusd — the reference server, run by
/// the IETF draft's own editor — still ships its IETF dialect
/// off-by-default as experimental. Building the foundation on a moving
/// spec whose clients do not exist would repeat a mistake Flight has
/// already declined once. The IETF dialect is additive when it settles:
/// everything below the header layer here — offsets, the store, the state
/// machine — is dialect-independent.
///
/// ```swift
/// let store = try DiskUploadStore(directory: uploadsDirectory)
/// container.pipeline("uploads") { RequestLogging.self }
/// container.uploads(at: "/uploads", store: store, pipelines: ["uploads"]) { options in
///     options.maxSize = 2 << 30
///     options.ttl = .seconds(24 * 3600)
/// }
/// ```
///
/// Supported extensions: `creation`, `creation-with-upload`, `termination`,
/// `expiration`. Deliberately absent: `concatenation` and `checksum` (no
/// consumer yet), and `creation-defer-length` — an upload whose size is
/// unknown at creation cannot be checked against `maxSize` until it is too
/// late to matter.
public struct UploadMountOptions: Sendable {
    /// Refused at creation with 413, and advertised as `Tus-Max-Size`.
    public var maxSize: Int64 = 1 << 30
    /// How long an unfinished upload survives; each response carries
    /// `Upload-Expires`. Sweeping is the application's to schedule (see
    /// ``UploadStore/sweepExpired(now:)``) — the mount never sweeps behind
    /// your back, because how often to do it is a deployment decision.
    public var ttl: Duration = .seconds(7 * 24 * 3600)
    /// Cap on a single `PATCH` body. Distinct from `maxSize`: the upload as
    /// a whole may be gigabytes while each append stays modest, which is
    /// how browsers upload (they cannot stream a request body over
    /// HTTP/1.1, so tus-js-client sends bounded chunks).
    public var maxChunkBytes = 512 << 20

    public init() {}
}

extension Container {
    /// Mounts the tus 1.0 endpoints at `prefix`.
    ///
    /// Real routes, not a fallback like the asset mount: tus is a finite,
    /// known route set, so registering it as five ordinary routes means it
    /// appears in the route table, in startup logs, and in actuator
    /// introspection like everything else — and it composes with pipeline
    /// lanes the same way. The `PATCH` route registers as streaming-bodied,
    /// making it the framework's own first consumer of that capability.
    public func uploads(
        at prefix: String,
        store: any UploadStore,
        pipelines: [String] = [MiddlewareRegistration.defaultLane],
        _ configure: (inout UploadMountOptions) -> Void = { _ in }
    ) {
        var options = UploadMountOptions()
        configure(&options)
        let base = prefix.hasSuffix("/") && prefix != "/" ? String(prefix.dropLast()) : prefix
        let mount = TusMount(prefix: base, store: store, options: options)
        let source = "uploads@\(base)"

        registerRoute(.options, base, source: source, pipelines: pipelines) { _ in
            mount.capabilities()
        }
        registerRoute(
            .post, base, source: source, pipelines: pipelines,
            bodyMode: .streaming(maxBytes: options.maxChunkBytes)
        ) { context in
            await mount.stamped(context) { try await mount.create(context) }
        }
        registerRoute(.head, "\(base)/:id", source: source, pipelines: pipelines) { context in
            await mount.stamped(context) { try await mount.probe(context) }
        }
        registerRoute(
            .patch, "\(base)/:id", source: source, pipelines: pipelines,
            bodyMode: .streaming(maxBytes: options.maxChunkBytes)
        ) { context in
            await mount.stamped(context) { try await mount.append(context) }
        }
        registerRoute(.delete, "\(base)/:id", source: source, pipelines: pipelines) { context in
            await mount.stamped(context) { try await mount.cancel(context) }
        }
    }
}

/// The protocol layer: wire rules only. Every durability question belongs
/// to the store beneath it.
struct TusMount: Sendable {
    static let version = "1.0.0"
    static let offsetContentType = "application/offset+octet-stream"

    let prefix: String
    let store: any UploadStore
    let options: UploadMountOptions

    // MARK: Endpoints

    func capabilities() -> Response {
        // OPTIONS is the discovery request, so it alone is exempt from the
        // Tus-Resumable requirement it advertises.
        var headers = baseHeaders()
        headers[.tusVersion] = Self.version
        headers[.tusExtension] = "creation,creation-with-upload,termination,expiration"
        headers[.tusMaxSize] = "\(options.maxSize)"
        headers[.allow] = "OPTIONS,POST,HEAD,PATCH,DELETE"
        return .fixed(status: .noContent, headers: headers, body: Data())
    }

    func create(_ context: RequestContext) async throws -> Response {
        try requireProtocolVersion(context)
        if context.request.headers[.uploadDeferLength] != nil {
            throw ResumableUploadError.deferredLengthUnsupported
        }
        guard let rawLength = context.request.headers[.uploadLength],
            let length = Int64(rawLength), length >= 0
        else {
            throw ResumableUploadError.malformed("Upload-Length must be a non-negative integer")
        }
        guard length <= options.maxSize else {
            throw ResumableUploadError.tooLarge(limit: options.maxSize)
        }

        let id = UUID().uuidString.lowercased()
        let expires = Date().addingTimeInterval(
            TimeInterval(options.ttl.components.seconds))
        let info = UploadInfo(
            id: id, offset: 0, length: length,
            metadata: Self.parseMetadata(context.request.headers[.uploadMetadata]),
            expires: expires, isComplete: length == 0)
        try await store.create(info)

        var headers = baseHeaders()
        headers[.location] = "\(prefix)/\(id)"
        headers[.uploadExpires] = HTTPDate.format(expires)

        // creation-with-upload: a body on the creation request is the first
        // append, saving a round trip. Recognized by its content type —
        // without it, any body is ignored (the plain-creation case).
        if context.request.headers[.contentType] == Self.offsetContentType,
            let stream = context.request.bodyStream
        {
            let offset = try await store.append(id, expectedOffset: 0, chunks: stream.chunks)
            headers[.uploadOffset] = "\(offset)"
        }
        return .fixed(status: .created, headers: headers, body: Data())
    }

    func probe(_ context: RequestContext) async throws -> Response {
        try requireProtocolVersion(context)
        let info = try await load(context)
        var headers = baseHeaders()
        headers[.uploadOffset] = "\(info.offset)"
        if let length = info.length { headers[.uploadLength] = "\(length)" }
        if let expires = info.expires { headers[.uploadExpires] = HTTPDate.format(expires) }
        // Echoed back, as tus requires of a HEAD that has it: the metadata
        // was parsed and stored at creation and then never surfaced, so a
        // client resuming in a fresh process could not recover the filename
        // it had sent.
        let metadata = Self.renderMetadata(info.metadata)
        if !metadata.isEmpty { headers[.uploadMetadata] = metadata }
        // The resumption answer must never be cached — a stale offset would
        // make a client resume from the wrong place.
        headers[.cacheControl] = "no-store"
        return .fixed(status: .ok, headers: headers, body: Data())
    }

    func append(_ context: RequestContext) async throws -> Response {
        try requireProtocolVersion(context)
        guard context.request.headers[.contentType] == Self.offsetContentType else {
            throw UnsupportedMediaTypeError(
                received: context.request.headers[.contentType] ?? "(none)",
                accepted: [Self.offsetContentType])
        }
        guard let rawOffset = context.request.headers[.uploadOffset],
            let expectedOffset = Int64(rawOffset), expectedOffset >= 0
        else {
            throw ResumableUploadError.malformed("Upload-Offset must be a non-negative integer")
        }
        let info = try await load(context)
        guard let stream = context.request.bodyStream else {
            throw HTTPError(.internalServerError, "upload route was not streamed")
        }

        do {
            let offset = try await store.append(
                info.id, expectedOffset: expectedOffset, chunks: stream.chunks)
            var headers = baseHeaders()
            headers[.uploadOffset] = "\(offset)"
            if let expires = info.expires { headers[.uploadExpires] = HTTPDate.format(expires) }
            return .fixed(status: .noContent, headers: headers, body: Data())
        } catch let error as ResumableUploadError {
            // A mismatch answers with the truth in Upload-Offset, so the
            // client seeks there and retries instead of guessing.
            if case .offsetMismatch(let current) = error {
                var headers = baseHeaders()
                headers[.uploadOffset] = "\(current)"
                return context.coders.renderError(error.httpStatus, error.httpMessage)
                    .settingHeader(.uploadOffset, "\(current)")
                    .settingHeader(.tusResumable, Self.version)
                    .settingHeader(.cacheControl, headers[.cacheControl] ?? "no-store")
            }
            throw error
        }
    }

    func cancel(_ context: RequestContext) async throws -> Response {
        try requireProtocolVersion(context)
        let info = try await load(context)
        try await store.remove(info.id)
        return .fixed(status: .noContent, headers: baseHeaders(), body: Data())
    }

    // MARK: Shared rules

    private func baseHeaders() -> HTTPFields {
        var headers: HTTPFields = [:]
        headers[.tusResumable] = Self.version
        return headers
    }

    /// Runs one endpoint and stamps `Tus-Resumable` on whatever comes back.
    ///
    /// tus 1.0 requires that header on *every* response, and only the
    /// special-cased offset mismatch carried it: everything else went through
    /// the generic `errorResponse`, which knows nothing about tus. A client
    /// checking it — which the spec tells clients to do — saw a bare 404 or
    /// 412 from a server that is otherwise conformant. `TusVersionMismatch`
    /// likewise documented a `Tus-Version` on its 412 that never reached the
    /// wire.
    func stamped(
        _ context: RequestContext, _ body: () async throws -> Response
    ) async -> Response {
        var response: Response
        do {
            response = try await body()
        } catch let error as TusVersionMismatch {
            response = errorResponse(for: error, context: context)
                .settingHeader(.tusVersion, Self.version)
        } catch {
            response = errorResponse(for: error, context: context)
        }
        return response.settingHeader(.tusResumable, Self.version)
    }

    /// Every request but OPTIONS must name the protocol version it speaks;
    /// a mismatch is 412 with the version this server does speak.
    private func requireProtocolVersion(_ context: RequestContext) throws {
        guard context.request.headers[.tusResumable] == Self.version else {
            throw TusVersionMismatch()
        }
    }

    private func load(_ context: RequestContext) async throws -> UploadInfo {
        guard let id = context.pathParam("id"),
            let info = try await store.info(id)
        else { throw ResumableUploadError.notFound }
        if let expires = info.expires, expires < Date() {
            throw ResumableUploadError.expired
        }
        return info
    }

    /// The inverse of ``parseMetadata(_:)``, for echoing on HEAD. Keys are
    /// sorted so the header is stable between requests.
    static func renderMetadata(_ metadata: [String: Data]) -> String {
        metadata.keys.sorted()
            .map { key in
                let value = metadata[key] ?? Data()
                return value.isEmpty ? key : "\(key) \(value.base64EncodedString())"
            }
            .joined(separator: ",")
    }

    /// `Upload-Metadata: filename <base64>,filetype <base64>` — keys are
    /// plain, values base64. A pair with no value is a valueless key, which
    /// the spec allows.
    static func parseMetadata(_ raw: String?) -> [String: Data] {
        guard let raw else { return [:] }
        var metadata: [String: Data] = [:]
        for pair in raw.split(separator: ",") {
            let fields = pair.trimmingCharacters(in: .whitespaces).split(
                separator: " ", maxSplits: 1)
            guard let key = fields.first, !key.isEmpty else { continue }
            if fields.count == 2, let decoded = Data(base64Encoded: String(fields[1])) {
                metadata[String(key)] = decoded
            } else {
                metadata[String(key)] = Data()
            }
        }
        return metadata
    }
}

/// The client did not speak this server's tus version. 412 per the spec,
/// carrying `Tus-Version` so the client can see what is on offer.
struct TusVersionMismatch: HTTPErrorRepresentable, Sendable {
    let httpStatus: HTTPResponse.Status = .preconditionFailed
    let httpMessage = "Tus-Resumable must be \(TusMount.version)"
}

extension HTTPField.Name {
    static let tusResumable = HTTPField.Name("Tus-Resumable")!
    static let tusVersion = HTTPField.Name("Tus-Version")!
    static let tusExtension = HTTPField.Name("Tus-Extension")!
    static let tusMaxSize = HTTPField.Name("Tus-Max-Size")!
    static let uploadOffset = HTTPField.Name("Upload-Offset")!
    static let uploadLength = HTTPField.Name("Upload-Length")!
    static let uploadDeferLength = HTTPField.Name("Upload-Defer-Length")!
    static let uploadMetadata = HTTPField.Name("Upload-Metadata")!
    static let uploadExpires = HTTPField.Name("Upload-Expires")!
}
