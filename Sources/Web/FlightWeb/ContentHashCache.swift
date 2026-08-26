import Foundation

/// Strong content-hash validators for files, cached by file identity.
///
/// `EntityTag.file` is weak on purpose — device/inode/size/mtime says
/// "probably unchanged", and RFC 9110 forbids resuming a download
/// (`If-Range`) on "probably". This actor produces the strong alternative:
/// SHA-256 of the bytes, so `sha256-…` tags survive `If-Range`'s strong
/// comparison and stay stable across redeploys that rewrite mtimes without
/// changing content.
///
/// The design constraint worth stating, because a shipping Swift framework
/// got it exactly wrong: its content-hash mode declared cache storage and
/// never initialized it, so every request re-hashed the whole file into
/// memory and threw the digest away — an unbounded-memory DoS behind an
/// innocent flag. Here the failure shape is unrepresentable rather than
/// avoided: the actor **owns** its storage non-optionally, the capacity is
/// a required part of construction, eviction is true LRU, and concurrent
/// misses for one file coalesce onto a single hashing task instead of
/// racing to hash it N times.
public actor ContentHashCache {
    public struct Key: Hashable, Sendable {
        let deviceID: UInt64
        let inode: UInt64
        let count: Int64
        let modificationNanoseconds: Int64
        /// The load-bearing field, added after the adversarial test caught
        /// its absence: without ctime, an in-place rewrite that preserves
        /// size and forges mtime hits the old cache entry — and serves the
        /// old digest as a STRONG validator for new bytes, which is exactly
        /// the If-Range corruption this cache exists to prevent. The kernel
        /// bumps ctime on every write and on the mtime-forge itself, and
        /// userspace cannot set it.
        let changeNanoseconds: Int64
    }

    private var digests: [Key: String] = [:]
    /// LRU order, least-recent first. Entry count stays small (thousands),
    /// so index-based touch is O(n) over tiny n — measured before clever.
    private var order: [Key] = []
    private var inFlight: [Key: Task<String, any Error>] = [:]
    private let capacity: Int
    private let compute: @Sendable (FileByteSource) async throws -> String

    /// `capacity` in entries; a digest plus key is ~100 bytes, so the
    /// default caps the cache around half a megabyte — a built site has
    /// hundreds of files, not millions.
    public init(capacity: Int = 4096) {
        self.init(capacity: capacity) { source in
            var hasher = SHA256()
            for try await chunk in source.chunks(in: 0..<source.count) {
                hasher.update(chunk)
            }
            return hasher.hexDigest()
        }
    }

    /// Test seam: same machinery, injectable digest computation.
    init(capacity: Int, compute: @escaping @Sendable (FileByteSource) async throws -> String) {
        precondition(capacity > 0, "a zero-capacity cache is the bug this type exists to prevent")
        self.capacity = capacity
        self.compute = compute
    }

    /// The strong tag for this open file — cached by (device, inode, size,
    /// mtime-ns), so any change that alters bytes alters the key and any
    /// key hit is byte-accurate without re-reading the file.
    public func strongTag(for source: FileByteSource) async throws -> EntityTag {
        EntityTag("sha256-\(try await digest(for: source))", weak: false)
    }

    func digest(for source: FileByteSource) async throws -> String {
        let key = Key(
            deviceID: source.deviceID, inode: source.inode, count: source.count,
            modificationNanoseconds: source.modificationNanoseconds,
            changeNanoseconds: source.changeNanoseconds)
        if let cached = digests[key] {
            touch(key)
            return cached
        }
        if let running = inFlight[key] {
            return try await running.value
        }
        let compute = self.compute
        let task = Task { try await compute(source) }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        let digest = try await task.value
        insert(digest, for: key)
        return digest
    }

    private func touch(_ key: Key) {
        if let index = order.firstIndex(of: key) {
            order.remove(at: index)
            order.append(key)
        }
    }

    private func insert(_ digest: String, for key: Key) {
        if digests[key] == nil, digests.count >= capacity, let evicted = order.first {
            order.removeFirst()
            digests[evicted] = nil
        }
        digests[key] = digest
        order.append(key)
    }
}
