import Dispatch
import Foundation

#if canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#elseif canImport(Darwin)
    import Darwin
#endif

/// A regular file as a ``ByteSource``: opened once, `fstat`-ed once on the
/// open descriptor, read with `pread(2)`, closed deterministically when the
/// last reference drops.
///
/// **Open-once is the design.** The size, modification time, and identity
/// this type reports come from `fstat` on the *same descriptor* the bytes
/// come from — there is no separate stat-by-path whose answer can drift from
/// what a later open sees. That closes the classic serve-a-file TOCTOU (a
/// `Content-Length` from one stat, bytes from a different open) at the type
/// level rather than by care. The one residual hazard — the file truncated
/// *after* opening, under this same descriptor — surfaces as a thrown
/// ``ByteSourceError/truncated(expected:delivered:)`` mid-stream: a loudly
/// broken transfer, never a quietly short body under a already-sent length.
///
/// **No blocking on the cooperative pool.** Flight Web has no NIO
/// dependency, so this does not ride `NIOFileSystem`; each blocking syscall
/// (`open`, `fstat`, `pread`) is dispatched to a plain `DispatchQueue`
/// thread and awaited. Reads are `pread` — positioned, stateless — so there
/// is no shared file offset to race on, and one source could serve
/// concurrent range requests if it ever needed to.
///
/// Lifetime: the descriptor closes in `deinit`. Swift deinitialization is
/// deterministic, so a `Response` that is built and then abandoned — an
/// error path, a HEAD, middleware substituting its own answer — releases
/// the descriptor as soon as the response value is dropped, with no
/// explicit close for every path to remember.
public final class FileByteSource: ByteSource, @unchecked Sendable {
    // @unchecked: `fd` is immutable after init and closed only in deinit;
    // every other stored property is a `let`. The compiler cannot see that
    // an Int32 file descriptor is safe to read concurrently, but it is.

    public struct OpenOptions: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        /// Refuse to open if the *final* path component is a symbolic link
        /// (`O_NOFOLLOW`). Containment of links in intermediate components is
        /// the asset provider's job — it resolves the whole path — but this
        /// closes the race between its check and this open.
        public static let noFollowLeaf = OpenOptions(rawValue: 1 << 0)
    }

    private let fd: Int32
    public let path: String
    /// Size at open, from `fstat` on the open descriptor.
    public let count: Int64
    /// Modification time at open, truncated to whole seconds — the
    /// resolution `Last-Modified` and `If-Modified-Since` speak.
    public let modificationDate: Date
    /// Modification time at full filesystem resolution, for validators:
    /// two writes inside one second are distinguishable here and not in
    /// `modificationDate`, which is exactly why an ETag built from this is
    /// stronger than one built from the HTTP-resolution date.
    public let modificationNanoseconds: Int64
    /// Device and inode, the other half of a file's identity for validators
    /// — two paths to the same inode share an ETag, a replaced file (new
    /// inode, same path) does not keep one.
    public let deviceID: UInt64
    public let inode: UInt64

    /// The default read size. Large enough that syscall and hop overhead
    /// amortizes, small enough that one connection holds one buffer of
    /// bounded size regardless of file size.
    public static let defaultChunkSize = 128 << 10

    /// One queue for all blocking file syscalls, concurrent so N slow reads
    /// (cold cache, network filesystem) do not serialize behind each other.
    /// Its threads belong to libdispatch, not to Swift's cooperative pool —
    /// which is the entire point: `Data(contentsOf:)` in an async handler
    /// parks a cooperative thread for the duration of disk I/O, and the
    /// cooperative pool has roughly one thread per core to lose.
    private static let ioQueue = DispatchQueue(
        label: "flight.web.file-io", qos: .userInitiated, attributes: .concurrent)

    /// Opens `path`, captures its metadata from the open descriptor, and
    /// returns a source positioned to serve it. Throws
    /// ``ByteSourceError/notAFile(_:)`` for directories and other
    /// non-regular files, and `.io` for anything the OS refuses.
    public static func open(
        atPath path: String, options: OpenOptions = []
    ) async throws -> FileByteSource {
        try await blocking {
            var flags = O_RDONLY | O_CLOEXEC
            if options.contains(.noFollowLeaf) { flags |= O_NOFOLLOW }
            let fd = retryingOnInterrupt { Glibc_open(path, flags) }
            guard fd >= 0 else {
                return .failure(ByteSourceError.io(operation: "open(\(path))", code: errno))
            }
            var status = stat()
            guard fstat(fd, &status) == 0 else {
                let code = errno
                _ = systemClose(fd)
                return .failure(ByteSourceError.io(operation: "fstat(\(path))", code: code))
            }
            guard (status.st_mode & S_IFMT) == S_IFREG else {
                _ = systemClose(fd)
                return .failure(ByteSourceError.notAFile(path))
            }
            #if canImport(Darwin)
                let ts = status.st_mtimespec
            #else
                let ts = status.st_mtim
            #endif
            return .success(
                FileByteSource(
                    fd: fd,
                    path: path,
                    count: Int64(status.st_size),
                    modificationSeconds: Int64(ts.tv_sec),
                    modificationNanosecondsPart: Int64(ts.tv_nsec),
                    deviceID: UInt64(bitPattern: Int64(status.st_dev)),
                    inode: UInt64(status.st_ino)
                ))
        }
    }

    private init(
        fd: Int32, path: String, count: Int64,
        modificationSeconds: Int64, modificationNanosecondsPart: Int64,
        deviceID: UInt64, inode: UInt64
    ) {
        self.fd = fd
        self.path = path
        self.count = count
        self.modificationDate = Date(timeIntervalSince1970: TimeInterval(modificationSeconds))
        self.modificationNanoseconds = modificationSeconds * 1_000_000_000 + modificationNanosecondsPart
        self.deviceID = deviceID
        self.inode = inode
    }

    deinit {
        _ = systemClose(fd)
    }

    public func chunks(in range: Range<Int64>, chunkSize: Int = FileByteSource.defaultChunkSize)
        -> AsyncThrowingStream<Data, any Error>
    {
        precondition(
            range.lowerBound >= 0 && range.upperBound <= count,
            "range \(range) outside 0..<\(count)")
        precondition(chunkSize > 0, "chunkSize must be positive")
        return AsyncThrowingStream { continuation in
            let reader = Task {
                var offset = range.lowerBound
                let end = range.upperBound
                do {
                    while offset < end {
                        try Task.checkCancellation()
                        let want = Int(min(Int64(chunkSize), end - offset))
                        let chunk = try await self.read(at: offset, count: want)
                        if chunk.isEmpty {
                            // pread past the current EOF: the file shrank
                            // after open. The promised Content-Length is
                            // already on the wire — fail the transfer loudly.
                            throw ByteSourceError.truncated(
                                expected: end - range.lowerBound,
                                delivered: offset - range.lowerBound)
                        }
                        offset += Int64(chunk.count)
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { reason in
                if case .cancelled = reason { reader.cancel() }
            }
        }
    }

    /// One positioned read, off the cooperative pool. May return fewer bytes
    /// than asked (signal, page boundary) — the caller loops; returns empty
    /// exactly at EOF.
    private func read(at offset: Int64, count: Int) async throws -> Data {
        let fd = self.fd
        return try await Self.blocking {
            var buffer = Data(count: count)
            let bytesRead = buffer.withUnsafeMutableBytes { raw -> Int in
                retryingOnInterrupt {
                    pread(fd, raw.baseAddress, count, off_t(offset))
                }
            }
            guard bytesRead >= 0 else {
                return .failure(ByteSourceError.io(operation: "pread", code: errno))
            }
            buffer.removeSubrange(bytesRead..<buffer.count)
            return .success(buffer)
        }
    }

    /// Runs a blocking syscall body on the IO queue and awaits its result.
    /// `realpath(3)` on the shared IO queue: the fully-resolved absolute
    /// path — every symlink followed, every `.` and `..` collapsed — or nil
    /// when the path does not fully exist. The asset layer's containment
    /// check ("does this resolve to somewhere under the root?") is built on
    /// this; asking the filesystem is the only version of that question
    /// that symlinks and encodings cannot lie to.
    internal static func realPath(_ path: String) async -> String? {
        try? await blocking {
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
            guard realpath(path, &buffer) != nil else {
                return .failure(ByteSourceError.io(operation: "realpath(\(path))", code: errno))
            }
            return .success(String(cString: buffer))
        }
    }

    internal static func blocking<T: Sendable>(
        _ body: @escaping @Sendable () -> Result<T, any Error>
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            ioQueue.async {
                continuation.resume(with: body())
            }
        }
    }
}

/// `open(2)` under a name that cannot collide with Foundation's `open`
/// overloads across platforms.
private func Glibc_open(_ path: String, _ flags: Int32) -> Int32 {
    #if canImport(Darwin)
        return Darwin.open(path, flags)
    #elseif canImport(Musl)
        return Musl.open(path, flags)
    #else
        return Glibc.open(path, flags)
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

/// Retries a syscall interrupted by a signal — the loop every raw-fd caller
/// must remember and this file remembers once.
private func retryingOnInterrupt<R: FixedWidthInteger>(_ body: () -> R) -> R {
    while true {
        let result = body()
        if result == -1 && errno == EINTR { continue }
        return result
    }
}
