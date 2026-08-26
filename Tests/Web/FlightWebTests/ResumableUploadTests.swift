import FlightCore
import FlightWebTesting
import Foundation
import HTTPTypes
import Synchronization
import Testing

@testable import FlightWeb

// tus 1.0 end to end, plus the durability rules underneath it. The tests
// that matter most are the ones about interruption: a resumable upload is
// only worth having if a dropped connection and a crash both leave the
// client able to continue from a truthful offset.

private let tusVersion = "1.0.0"

private struct UploadHarness {
    let client: TestClient
    let store: DiskUploadStore
    let directory: URL
    let container: Container
}

/// Hoisted: a type cannot nest in a generic function. Its configuration
/// rides a static box because TestContainer instantiates modules itself.
private struct UploadModule: FlightModule {
    static let state = Mutex<(store: DiskUploadStore?, maxSize: Int64)>((nil, 0))

    func configure(_ container: Container) throws {
        let (store, maxSize) = Self.state.withLock { $0 }
        container.uploads(at: "/uploads", store: store!) { options in
            options.maxSize = maxSize
        }
    }
}

private func withUploads<T>(
    maxSize: Int64 = 1 << 20,
    flushInterval: Int64 = 8 << 20,
    _ body: (UploadHarness) async throws -> T
) async throws -> T {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("flight-uploads-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try DiskUploadStore(directory: directory, flushInterval: flushInterval)

    UploadModule.state.withLock { $0 = (store, maxSize) }
    let container = try TestContainer.build { UploadModule() }
    let client = try TestClient(container: container)
    return try await body(
        UploadHarness(client: client, store: store, directory: directory, container: container))
}

extension TestClient {
    /// A tus request: the protocol header is on every call but OPTIONS.
    fileprivate func tus(
        _ method: HTTPRequest.Method, _ path: String,
        headers extra: [HTTPField.Name: String] = [:],
        chunks: [Data]? = nil,
        omitVersion: Bool = false
    ) async -> Response {
        var headers: HTTPFields = [:]
        if !omitVersion { headers[.tusResumable] = tusVersion }
        for (name, value) in extra { headers[name] = value }
        var request = Request(method: method, path: path, headers: headers)
        if let chunks {
            let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
            request.bodyStream = RequestBodyStream(
                expectedBytes: Int64(chunks.reduce(0) { $0 + $1.count }), chunks: stream)
        }
        return await execute(request)
    }
}

// Serialized: the mount's configuration reaches TestContainer through a
// static box (it instantiates modules itself), so two tests building
// mounts concurrently would swap each other's stores.
@Suite("tus 1.0 — protocol", .serialized)
struct TusProtocolTests {

    @Test("OPTIONS advertises the version, extensions, and max size")
    func capabilities() async throws {
        try await withUploads(maxSize: 5_000) { app in
            let response = await app.client.tus(.options, "/uploads", omitVersion: true)
            #expect(response.status == .noContent)
            #expect(response.headers[.tusResumable] == tusVersion)
            #expect(response.headers[.tusVersion] == tusVersion)
            #expect(response.headers[.tusMaxSize] == "5000")
            let extensions = try #require(response.headers[.tusExtension])
            for expected in ["creation", "creation-with-upload", "termination", "expiration"] {
                #expect(extensions.contains(expected))
            }
        }
    }

    @Test("a missing or wrong Tus-Resumable is 412, not a confusing 4xx")
    func versionGate() async throws {
        try await withUploads { app in
            let missing = await app.client.tus(
                .post, "/uploads", headers: [.uploadLength: "10"], omitVersion: true)
            #expect(missing.status == .preconditionFailed)

            var headers: HTTPFields = [:]
            headers[.tusResumable] = "0.9.0"
            headers[.uploadLength] = "10"
            let wrong = await app.client.execute(
                Request(method: .post, path: "/uploads", headers: headers))
            #expect(wrong.status == .preconditionFailed)
        }
    }

    @Test("create → probe → append → complete, the ordinary path")
    func happyPath() async throws {
        try await withUploads { app in
            let payload = Data((0..<3_000).map { UInt8($0 % 251) })
            let created = await app.client.tus(
                .post, "/uploads", headers: [.uploadLength: "\(payload.count)"])
            #expect(created.status == .created)
            let location = try #require(created.headers[.location])
            #expect(location.hasPrefix("/uploads/"))
            #expect(created.headers[.uploadExpires] != nil)

            let empty = await app.client.tus(.head, location)
            #expect(empty.status == .ok)
            #expect(empty.headers[.uploadOffset] == "0")
            #expect(empty.headers[.uploadLength] == "\(payload.count)")
            #expect(empty.headers[.cacheControl] == "no-store")

            let first = await app.client.tus(
                .patch, location,
                headers: [.contentType: TusMount.offsetContentType, .uploadOffset: "0"],
                chunks: [payload.prefix(1_000)])
            #expect(first.status == .noContent)
            #expect(first.headers[.uploadOffset] == "1000")

            let rest = await app.client.tus(
                .patch, location,
                headers: [.contentType: TusMount.offsetContentType, .uploadOffset: "1000"],
                chunks: [Data(payload.dropFirst(1_000))])
            #expect(rest.headers[.uploadOffset] == "3000")

            let id = String(location.dropFirst("/uploads/".count))
            let info = try #require(try await app.store.info(id))
            #expect(info.isComplete)

            // The bytes on disk are the bytes sent, exactly.
            let source = try await app.store.readable(id)
            var stored = Data()
            for try await chunk in source.chunks(in: 0..<source.count, chunkSize: 4_096) {
                stored.append(chunk)
            }
            #expect(stored == payload)
        }
    }

    @Test("creation-with-upload accepts the first bytes on the POST")
    func creationWithUpload() async throws {
        try await withUploads { app in
            let payload = Data("inline creation body".utf8)
            let created = await app.client.tus(
                .post, "/uploads",
                headers: [
                    .uploadLength: "\(payload.count)",
                    .contentType: TusMount.offsetContentType,
                ],
                chunks: [payload])
            #expect(created.status == .created)
            #expect(created.headers[.uploadOffset] == "\(payload.count)")
        }
    }

    @Test("Upload-Metadata is decoded and kept verbatim")
    func metadata() async throws {
        try await withUploads { app in
            let filename = Data("résumé.pdf".utf8).base64EncodedString()
            let created = await app.client.tus(
                .post, "/uploads",
                headers: [
                    .uploadLength: "4",
                    .uploadMetadata: "filename \(filename),confidential",
                ])
            let id = String(
                try #require(created.headers[.location]).dropFirst("/uploads/".count))
            let info = try #require(try await app.store.info(id))
            #expect(info.metadata["filename"] == Data("résumé.pdf".utf8))
            #expect(info.metadata["confidential"] == Data(), "a valueless key is allowed")
        }
    }

    @Test("THE resumption case: a stale offset is refused with the truth, never applied twice")
    func staleOffsetRefused() async throws {
        try await withUploads { app in
            let created = await app.client.tus(
                .post, "/uploads", headers: [.uploadLength: "20"])
            let location = try #require(created.headers[.location])

            _ = await app.client.tus(
                .patch, location,
                headers: [.contentType: TusMount.offsetContentType, .uploadOffset: "0"],
                chunks: [Data(repeating: 0x41, count: 10)])

            // The client never saw the 204 (connection died after the server
            // committed) and retries from 0. Applying this twice would
            // duplicate ten bytes into the middle of the file — the exact
            // corruption resumability must not cause.
            let retry = await app.client.tus(
                .patch, location,
                headers: [.contentType: TusMount.offsetContentType, .uploadOffset: "0"],
                chunks: [Data(repeating: 0x41, count: 10)])
            #expect(retry.status == .conflict)
            #expect(retry.headers[.uploadOffset] == "10", "the response carries the real offset")

            // And the upload is still exactly ten bytes along.
            let probe = await app.client.tus(.head, location)
            #expect(probe.headers[.uploadOffset] == "10")
        }
    }

    @Test("an append past the declared length is refused, prior bytes intact")
    func overrunRefused() async throws {
        try await withUploads { app in
            let created = await app.client.tus(
                .post, "/uploads", headers: [.uploadLength: "10"])
            let location = try #require(created.headers[.location])
            let response = await app.client.tus(
                .patch, location,
                headers: [.contentType: TusMount.offsetContentType, .uploadOffset: "0"],
                chunks: [Data(repeating: 0x42, count: 50)])
            #expect(response.status == .contentTooLarge)

            let probe = await app.client.tus(.head, location)
            #expect(probe.headers[.uploadOffset] == "0")
        }
    }

    @Test("wrong content type on PATCH is 415; unknown id is 404; DELETE removes")
    func protocolEdges() async throws {
        try await withUploads { app in
            let created = await app.client.tus(
                .post, "/uploads", headers: [.uploadLength: "4"])
            let location = try #require(created.headers[.location])

            let wrongType = await app.client.tus(
                .patch, location,
                headers: [.contentType: "application/octet-stream", .uploadOffset: "0"],
                chunks: [Data("abcd".utf8)])
            #expect(wrongType.status == .unsupportedMediaType)

            #expect(await app.client.tus(.head, "/uploads/deadbeef").status == .notFound)
            #expect(await app.client.tus(.patch, "/uploads/../etc/passwd").status == .notFound)

            #expect(await app.client.tus(.delete, location).status == .noContent)
            #expect(await app.client.tus(.head, location).status == .notFound)
        }
    }

    @Test("creation refuses a length over the mount's maximum, and deferred length")
    func creationLimits() async throws {
        try await withUploads(maxSize: 100) { app in
            let tooBig = await app.client.tus(
                .post, "/uploads", headers: [.uploadLength: "101"])
            #expect(tooBig.status == .contentTooLarge)

            let deferred = await app.client.tus(
                .post, "/uploads", headers: [.uploadDeferLength: "1"])
            #expect(deferred.status == .badRequest)

            let missing = await app.client.tus(.post, "/uploads")
            #expect(missing.status == .badRequest)
        }
    }

    @Test("the mount registers as ordinary routes, streaming where it must")
    func routeTableShape() async throws {
        try await withUploads { app in
            let routes = try app.container.collectRoutes()
                .filter { $0.source.hasPrefix("uploads@") }
            #expect(routes.count == 5)
            let patch = try #require(routes.first { $0.method == .patch })
            guard case .streaming = patch.bodyMode else {
                Issue.record("PATCH must stream — it is the framework's own consumer of that")
                return
            }
            #expect(routes.contains { $0.method == .options })
            #expect(routes.contains { $0.method == .delete })
        }
    }
}

@Suite("upload durability")
struct UploadDurabilityTests {

    private func withStore<T>(
        flushInterval: Int64 = 8 << 20, _ body: (DiskUploadStore, URL) async throws -> T
    ) async throws -> T {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("flight-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try DiskUploadStore(directory: directory, flushInterval: flushInterval)
        return try await body(store, directory)
    }

    private func stream(_ chunks: [Data], failAfter: Int? = nil) -> AsyncThrowingStream<Data, any Error>
    {
        let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        for (index, chunk) in chunks.enumerated() {
            if let failAfter, index == failAfter {
                continuation.finish(throwing: URLError(.networkConnectionLost))
                return stream
            }
            continuation.yield(chunk)
        }
        continuation.finish()
        return stream
    }

    @Test("a dropped connection keeps every flushed byte and reports it honestly")
    func disconnectMidAppend() async throws {
        // Flush every 1 KiB so the interruption lands after real durability
        // points — the shape of a real slow upload.
        try await withStore(flushInterval: 1_024) { store, _ in
            let info = UploadInfo(id: "aaaa-1111", length: 10_000)
            try await store.create(info)

            let chunks = (0..<10).map { _ in Data(repeating: 0x5A, count: 1_024) }
            await #expect(throws: (any Error).self) {
                _ = try await store.append(
                    "aaaa-1111", expectedOffset: 0,
                    chunks: self.stream(chunks, failAfter: 5))
            }

            // Five KiB were flushed before the drop; the recorded offset
            // must be exactly that — never optimistic, never zero.
            let after = try #require(try await store.info("aaaa-1111"))
            #expect(after.offset == 5 * 1_024)
            #expect(!after.isComplete)

            // And the client resumes from there and finishes.
            let resumed = try await store.append(
                "aaaa-1111", expectedOffset: after.offset,
                chunks: self.stream([Data(repeating: 0x5A, count: 10_000 - 5 * 1_024)]))
            #expect(resumed == 10_000)
            let complete = try #require(try await store.info("aaaa-1111"))
            #expect(complete.isComplete)
        }
    }

    @Test("bytes past the recorded offset are truncated away on the next append")
    func crashRuleReconciliation() async throws {
        try await withStore { store, directory in
            try await store.create(UploadInfo(id: "bbbb-2222", length: 100))
            _ = try await store.append(
                "bbbb-2222", expectedOffset: 0, chunks: stream([Data(repeating: 0x01, count: 40)]))

            // Simulate the crash window: bytes made it to the file, the
            // offset record did not. Keeping them would put every later
            // append at the wrong place.
            let dataPath = directory.appendingPathComponent("bbbb-2222.bin")
            let handle = try FileHandle(forWritingTo: dataPath)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(repeating: 0xFF, count: 25))
            try handle.close()
            #expect(try Data(contentsOf: dataPath).count == 65)

            // The next append reconciles first, so the unacknowledged tail
            // is gone and the new bytes land exactly at offset 40.
            let offset = try await store.append(
                "bbbb-2222", expectedOffset: 40,
                chunks: stream([Data(repeating: 0x02, count: 10)]))
            #expect(offset == 50)
            let bytes = try Data(contentsOf: dataPath)
            #expect(bytes.count == 50)
            #expect(bytes[40..<50].allSatisfy { $0 == 0x02 })
            #expect(!bytes.contains(0xFF), "unacknowledged bytes must not survive")
        }
    }

    @Test("concurrent appends to one id are refused, not interleaved")
    func concurrentAppendsRefused() async throws {
        try await withStore { store, _ in
            try await store.create(UploadInfo(id: "cccc-3333", length: 4_000))
            // A slow stream, so the second append arrives mid-flight.
            let (slow, slowContinuation) = AsyncThrowingStream<Data, any Error>.makeStream()
            async let first = store.append("cccc-3333", expectedOffset: 0, chunks: slow)
            try await Task.sleep(for: .milliseconds(50))

            await #expect(throws: ResumableUploadError.uploadBusy) {
                _ = try await store.append(
                    "cccc-3333", expectedOffset: 0,
                    chunks: self.stream([Data(repeating: 0x09, count: 10)]))
            }
            slowContinuation.yield(Data(repeating: 0x08, count: 4_000))
            slowContinuation.finish()
            #expect(try await first == 4_000)
        }
    }

    @Test("expired uploads are gone, and sweeping removes them")
    func expiry() async throws {
        try await withStore { store, _ in
            try await store.create(
                UploadInfo(
                    id: "dddd-4444", length: 10,
                    expires: Date().addingTimeInterval(-60)))
            await #expect(throws: ResumableUploadError.expired) {
                _ = try await store.append(
                    "dddd-4444", expectedOffset: 0, chunks: self.stream([Data("x".utf8)]))
            }
            #expect(try await store.sweepExpired(now: Date()) == 1)
            #expect(try await store.info("dddd-4444") == nil)
        }
    }

    @Test("unsafe ids never reach the filesystem")
    func idHardening() {
        #expect(!DiskUploadStore.isSafeID("../../etc/passwd"))
        #expect(!DiskUploadStore.isSafeID("a/b"))
        #expect(!DiskUploadStore.isSafeID(""))
        #expect(!DiskUploadStore.isSafeID(String(repeating: "a", count: 65)))
        #expect(DiskUploadStore.isSafeID(UUID().uuidString.lowercased()))
    }
}
