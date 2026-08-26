import Dispatch
import Foundation

#if canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#elseif canImport(Darwin)
    import Darwin
#endif

/// An ``UploadStore`` on the local filesystem: `{id}.bin` for the bytes,
/// `{id}.json` beside it for the offset and metadata.
///
/// **The crash rule**, which is the entire reason a resumable upload
/// survives a power cut rather than merely a dropped connection:
///
/// 1. Bytes are written, then **fsynced**.
/// 2. Only then is the new offset recorded, by writing the sidecar to a
///    temp file and **atomically renaming** it over the old one.
/// 3. On reopening an upload, if the data file is **longer** than the
///    recorded offset, the excess is **truncated away**.
///
/// Step 3 is what makes step 1's ordering safe. Bytes past the recorded
/// offset were never acknowledged to any client, so discarding them costs
/// nothing — the client re-sends them — while keeping them would leave a
/// file whose length disagrees with its recorded offset, and every
/// subsequent append would write at the wrong place. Reversing steps 1 and
/// 2 would produce the genuinely dangerous version: a recorded offset
/// covering bytes that never reached the disk, and a resuming client
/// stitching new data onto a hole.
///
/// Between fsyncs, the sidecar is refreshed every ``flushInterval`` bytes,
/// so an abrupt disconnect loses at most that much — the client's next
/// `HEAD` reports the true durable offset and it re-sends only the tail.
public actor DiskUploadStore: UploadStore {
    private let directory: URL
    /// Bytes appended between durability points. Larger means fewer fsyncs
    /// (faster) and more to re-send after a crash; 8 MiB is a few seconds
    /// of a slow connection.
    private let flushInterval: Int64
    /// Ids with an append in flight. Actors are reentrant — two appends to
    /// one id would happily interleave at their `await`s — so exclusion is
    /// explicit rather than implied by actor isolation.
    private var appending: Set<String> = []

    private static let ioQueue = DispatchQueue(
        label: "flight.web.upload-io", qos: .userInitiated, attributes: .concurrent)

    public init(directory: URL, flushInterval: Int64 = 8 << 20) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        self.directory = directory
        self.flushInterval = flushInterval
    }

    // MARK: - UploadStore

    public func create(_ info: UploadInfo) async throws {
        guard Self.isSafeID(info.id) else {
            throw ResumableUploadError.malformed("unsafe upload id")
        }
        FileManager.default.createFile(atPath: dataURL(info.id).path, contents: nil)
        try writeSidecar(info)
    }

    public func info(_ id: String) async throws -> UploadInfo? {
        guard Self.isSafeID(id), let stored = try readSidecar(id) else { return nil }
        return stored
    }

    public func append(
        _ id: String, expectedOffset: Int64, chunks: AsyncThrowingStream<Data, any Error>
    ) async throws -> Int64 {
        guard Self.isSafeID(id) else { throw ResumableUploadError.notFound }
        guard !appending.contains(id) else { throw ResumableUploadError.uploadBusy }
        appending.insert(id)
        defer { appending.remove(id) }

        guard var info = try readSidecar(id) else { throw ResumableUploadError.notFound }
        if let expires = info.expires, expires < Date() {
            throw ResumableUploadError.expired
        }
        guard !info.isComplete else { throw ResumableUploadError.alreadyComplete }
        // The atomic check: inside the exclusion, against the durable
        // offset. A retried append at a stale offset lands here and is
        // refused with the truth, never applied a second time.
        guard info.offset == expectedOffset else {
            throw ResumableUploadError.offsetMismatch(current: info.offset)
        }

        // Reconcile before writing: bytes past the recorded offset were
        // never acknowledged, so they are discarded rather than trusted.
        try await reconcile(id, to: info.offset)

        let path = dataURL(id).path
        let descriptor = try await Self.blocking {
            let fd = openForWriting(path)
            return fd >= 0
                ? .success(fd)
                : .failure(ResumableUploadError.malformed("cannot open upload data"))
        }
        defer { _ = systemClose(descriptor) }

        var pendingSinceFlush: Int64 = 0
        var writeOffset = info.offset

        do {
            for try await chunk in chunks {
                guard !chunk.isEmpty else { continue }
                if let length = info.length, writeOffset + Int64(chunk.count) > length {
                    // Refuse the overrun, but keep what is already durable —
                    // the client is wrong about the tail, not about the head.
                    if pendingSinceFlush > 0 {
                        info = try recordDurable(
                            info,
                            at: try await DurablePoint.reached(writeOffset, syncing: descriptor))
                    }
                    throw ResumableUploadError.exceedsDeclaredLength(length: length)
                }
                let written = try await Self.write(chunk, to: descriptor, at: writeOffset)
                writeOffset += written
                pendingSinceFlush += written
                if pendingSinceFlush >= flushInterval {
                    info = try recordDurable(
                        info, at: try await DurablePoint.reached(writeOffset, syncing: descriptor))
                    pendingSinceFlush = 0
                }
            }
        } catch let error as ResumableUploadError {
            throw error
        } catch {
            // A dropped connection mid-body: whatever is already durable
            // stays durable, and the client's next HEAD reports exactly it.
            // Bytes already written are real bytes the client sent, so
            // they are synced and kept — that is what shrinks the re-send
            // to the last partial batch instead of the whole append.
            if pendingSinceFlush > 0,
                let point = try? await DurablePoint.reached(writeOffset, syncing: descriptor)
            {
                info = (try? recordDurable(info, at: point)) ?? info
            }
            throw error
        }
        if pendingSinceFlush > 0 {
            info = try recordDurable(
                info, at: try await DurablePoint.reached(writeOffset, syncing: descriptor))
        }
        return info.offset
    }

    /// Records an offset that a ``DurablePoint`` proves is on disk.
    ///
    /// Takes the proof rather than the number: the crash rule's ordering —
    /// fsync, *then* record — is the one rule here that no in-process test
    /// can check, because skipping the fsync produces identical results
    /// until the power actually fails. So it is enforced by construction
    /// instead. A `DurablePoint` cannot be made without an fsync, and this
    /// is the only path that advances a recorded offset, which makes
    /// "record bytes that never reached the disk" unwritable rather than
    /// merely untested.
    private func recordDurable(_ info: UploadInfo, at point: DurablePoint) throws -> UploadInfo {
        var updated = info
        updated.offset = point.offset
        updated.isComplete = updated.length.map { point.offset >= $0 } ?? false
        try writeSidecar(updated)
        return updated
    }

    public func remove(_ id: String) async throws {
        guard Self.isSafeID(id) else { throw ResumableUploadError.notFound }
        try? FileManager.default.removeItem(at: dataURL(id))
        try? FileManager.default.removeItem(at: sidecarURL(id))
    }

    public func sweepExpired(now: Date) async throws -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        var removed = 0
        for name in names where name.hasSuffix(".json") {
            let id = String(name.dropLast(5))
            guard let info = try? readSidecar(id), let expires = info.expires else { continue }
            if expires < now {
                try await remove(id)
                removed += 1
            }
        }
        return removed
    }

    public func readable(_ id: String) async throws -> any ByteSource {
        guard Self.isSafeID(id), let info = try readSidecar(id) else {
            throw ResumableUploadError.notFound
        }
        // Never serve past the durable offset, even if stray bytes sit in
        // the file after an unclean shutdown.
        try await reconcile(id, to: info.offset)
        return try await FileByteSource.open(atPath: dataURL(id).path)
    }

    // MARK: - Durability plumbing

    /// Truncates the data file down to `offset` when it is longer — the
    /// third step of the crash rule.
    private func reconcile(_ id: String, to offset: Int64) async throws {
        let path = dataURL(id).path
        let size = (try? await FileByteSource.open(atPath: path).count) ?? 0
        guard size > offset else { return }
        try await Self.blocking {
            truncate(path, off_t(offset)) == 0
                ? .success(())
                : .failure(ResumableUploadError.malformed("cannot truncate to the recorded offset"))
        }
    }

    private func dataURL(_ id: String) -> URL { directory.appendingPathComponent("\(id).bin") }
    private func sidecarURL(_ id: String) -> URL {
        directory.appendingPathComponent("\(id).json")
    }

    private func readSidecar(_ id: String) throws -> UploadInfo? {
        guard let data = try? Data(contentsOf: sidecarURL(id)) else { return nil }
        return try? JSONDecoder().decode(UploadInfo.self, from: data)
    }

    /// Temp file plus atomic rename: a sidecar is never observed
    /// half-written, so a crash mid-record leaves the *previous* offset —
    /// which is exactly the conservative direction.
    ///
    /// `rename(2)` rather than `FileManager.replaceItemAt`: rename replaces
    /// atomically whether or not the destination exists, while replaceItemAt
    /// requires an existing target and so cannot write the very first
    /// sidecar — the ordinary create path.
    private func writeSidecar(_ info: UploadInfo) throws {
        let target = sidecarURL(info.id)
        let temp = directory.appendingPathComponent("\(info.id).json.tmp")
        try JSONEncoder().encode(info).write(to: temp, options: .atomic)
        guard rename(temp.path, target.path) == 0 else {
            try? FileManager.default.removeItem(at: temp)
            throw ResumableUploadError.malformed("cannot record the upload offset")
        }
    }

    /// Ids reach the filesystem as path components; only server-minted
    /// shapes are ever accepted.
    static func isSafeID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64
            && id.allSatisfy { $0.isHexDigit || $0 == "-" }
    }

    private static func write(_ data: Data, to descriptor: Int32, at offset: Int64) async throws
        -> Int64
    {
        try await blocking {
            var total = 0
            let result: Int = data.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                while total < data.count {
                    let written = pwrite(
                        descriptor, base.advanced(by: total), data.count - total,
                        off_t(offset) + off_t(total))
                    if written < 0 {
                        if errno == EINTR { continue }
                        return -1
                    }
                    total += written
                }
                return total
            }
            return result < 0
                ? .failure(ResumableUploadError.malformed("write failed"))
                : .success(Int64(result))
        }
    }

    private static func blocking<T: Sendable>(
        _ body: @escaping @Sendable () -> Result<T, any Error>
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            ioQueue.async { continuation.resume(with: body()) }
        }
    }
}

private func openForWriting(_ path: String) -> Int32 {
    #if canImport(Darwin)
        return Darwin.open(path, O_WRONLY | O_CREAT | O_CLOEXEC, 0o600)
    #elseif canImport(Musl)
        return Musl.open(path, O_WRONLY | O_CREAT | O_CLOEXEC, 0o600)
    #else
        return Glibc.open(path, O_WRONLY | O_CREAT | O_CLOEXEC, 0o600)
    #endif
}

private func systemClose(_ fd: Int32) -> Int32 {
    #if canImport(Darwin)
        return Darwin.close(fd)
    #elseif canImport(Musl)
        return Musl.close(fd)
    #else
        return Glibc.close(fd)
    #endif
}

/// Evidence that every byte up to `offset` is on the disk, not merely in a
/// page cache.
///
/// Deliberately unforgeable: the initializer is private and the only way
/// to reach one is ``reached(_:syncing:)``, which performs the `fsync`. A
/// recorded upload offset is the number a resuming client continues from,
/// so recording one that outruns the disk turns a power cut into silent
/// corruption — the client resumes past a hole. Requiring this proof at
/// the recording site makes that mistake fail to compile rather than fail
/// in production, which matters here more than usual because it is exactly
/// the mistake no in-process test can observe.
struct DurablePoint {
    let offset: Int64

    private init(offset: Int64) { self.offset = offset }

    static func reached(_ offset: Int64, syncing descriptor: Int32) async throws -> DurablePoint {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                guard fsync(descriptor) == 0 else {
                    continuation.resume(
                        throwing: ResumableUploadError.malformed("fsync failed"))
                    return
                }
                continuation.resume(returning: ())
            }
        }
        return DurablePoint(offset: offset)
    }
}
