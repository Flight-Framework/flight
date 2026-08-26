import FlightCore
import Foundation
import FlightWebTesting
import HTTPTypes
import Synchronization
import Testing

@testable import FlightWeb

@Suite("SHA-256")
struct SHA256Tests {

    @Test("the FIPS 180-4 vectors")
    func nistVectors() {
        #expect(
            SHA256.hexDigest(of: Data())
                == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(
            SHA256.hexDigest(of: Data("abc".utf8))
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(
            SHA256.hexDigest(
                of: Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8))
                == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        #expect(
            SHA256.hexDigest(of: Data(repeating: UInt8(ascii: "a"), count: 1_000_000))
                == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }

    @Test("chunked updates equal the one-shot digest at hostile split points")
    func chunkingIsTransparent() {
        let message = Data((0..<1_000).map { UInt8($0 % 251) })
        let oneShot = SHA256.hexDigest(of: message)
        // Splits straddling the 64-byte block boundary and the padding edge.
        for split in [1, 55, 56, 63, 64, 65, 127, 128, 500, 999] {
            var hasher = SHA256()
            hasher.update(message.prefix(split))
            hasher.update(message.dropFirst(split))
            #expect(hasher.hexDigest() == oneShot, "split at \(split)")
        }
    }
}

@Suite("ContentHashCache")
struct ContentHashCacheTests {

    private func withFile<T>(
        _ content: Data, _ body: (FileByteSource, String) async throws -> T
    ) async throws -> T {
        let path = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("flight-hash-\(UUID().uuidString)").path
        try content.write(to: URL(fileURLWithPath: path))
        defer { try? FileManager.default.removeItem(atPath: path) }
        return try await body(try await FileByteSource.open(atPath: path), path)
    }

    @Test("a repeat request hits the cache — the file is hashed once, not per request")
    func cacheActuallyCaches() async throws {
        // The anti-pattern this type exists to prevent, pinned as a test:
        // a shipping framework's content-hash mode silently never cached,
        // re-hashing the whole file on every request.
        let computeCount = Mutex(0)
        let cache = ContentHashCache(capacity: 8) { source in
            computeCount.withLock { $0 += 1 }
            var hasher = SHA256()
            for try await chunk in source.chunks(in: 0..<source.count) { hasher.update(chunk) }
            return hasher.hexDigest()
        }
        try await withFile(Data("cache me".utf8)) { source, path in
            let first = try await cache.strongTag(for: source)
            let second = try await cache.strongTag(for: source)
            #expect(first == second)
            #expect(!first.isWeak, "the entire point is a strong validator")
            #expect(computeCount.withLock { $0 } == 1)

            // A fresh open of the unchanged file: same identity, still cached.
            let reopened = try await FileByteSource.open(atPath: path)
            _ = try await cache.strongTag(for: reopened)
            #expect(computeCount.withLock { $0 } == 1)
        }
    }

    @Test("capacity is enforced with LRU eviction")
    func lruEviction() async throws {
        let computeCount = Mutex(0)
        let cache = ContentHashCache(capacity: 2) { _ in
            computeCount.withLock { $0 += 1 }
            return "digest-\(computeCount.withLock { $0 })"
        }
        try await withFile(Data("a".utf8)) { a, _ in
            try await withFile(Data("bb".utf8)) { b, _ in
                try await withFile(Data("ccc".utf8)) { c, _ in
                    _ = try await cache.digest(for: a)  // {a}
                    _ = try await cache.digest(for: b)  // {a,b}
                    _ = try await cache.digest(for: a)  // touch a → b is LRU
                    _ = try await cache.digest(for: c)  // evicts b → {a,c}
                    #expect(computeCount.withLock { $0 } == 3)

                    _ = try await cache.digest(for: a)  // still cached
                    #expect(computeCount.withLock { $0 } == 3)
                    _ = try await cache.digest(for: b)  // evicted → recompute
                    #expect(computeCount.withLock { $0 } == 4)
                }
            }
        }
    }

    @Test("a changed file gets a new digest — the identity key sees the mtime move")
    func changedFileRekeys() async throws {
        let cache = ContentHashCache(capacity: 8)
        try await withFile(Data("version one".utf8)) { first, path in
            let before = try await cache.strongTag(for: first)
            try Data("version two".utf8).write(to: URL(fileURLWithPath: path))
            let after = try await cache.strongTag(for: try await FileByteSource.open(atPath: path))
            #expect(before != after)
        }
    }
}

@Suite("content-hash mounts — resumable downloads", .serialized)
struct ContentHashMountTests {

    @Test("If-Range resumption works end to end under .contentHash, and stays safe under identity")
    func ifRangeResumption() async throws {
        let site = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("flight-hashmount-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: site, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: site) }
        try Data("0123456789".utf8).write(to: site.appendingPathComponent("file.bin"))

        struct HashSiteModule: FlightModule {
            static let root = Mutex("")
            func configure(_ container: Container) throws {
                container.assets(at: "/", root: Self.root.withLock { $0 }) { options in
                    options.etag = .contentHash
                }
            }
        }
        HashSiteModule.root.withLock { $0 = site.path }
        let client = try TestClient(container: TestContainer.build { HashSiteModule() })

        let full = await client.get("/file.bin")
        let etag = try #require(full.headers[.eTag])
        #expect(etag.hasPrefix("\"sha256-"), "strong — no W/ prefix: \(etag)")

        // The careful client's resumption: Range guarded by If-Range.
        // Weak identity tags safely downgrade this to a full 200; strong
        // hash tags are what make it actually resume.
        let resumed = await client.get(
            "/file.bin", headers: [.range: "bytes=4-", .ifRange: etag])
        #expect(resumed.status == .partialContent)
        #expect(try await resumed.collectedBody() == Data("456789".utf8))

        // Stale validator: full body, never a mismatched slice.
        let stale = await client.get(
            "/file.bin", headers: [.range: "bytes=4-", .ifRange: "\"sha256-oldold\""])
        #expect(stale.status == .ok)

        // And revalidation still works with the hash tag.
        let revalidated = await client.get("/file.bin", headers: [.ifNoneMatch: etag])
        #expect(revalidated.status == .notModified)
    }

    @Test("same size, same forced mtime, different bytes: hash tags differ where identity tags cannot")
    func hashSeesWhatIdentityCannot() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("flight-collide-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("f").path
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)

        // Tag computed BEFORE the rewrite, as serving would — an in-place
        // rewrite reuses the inode, so hashing the old descriptor after the
        // rewrite would read the new bytes and prove nothing.
        let cache = ContentHashCache()
        try Data("AAAA".utf8).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: path)
        let firstTag = try await cache.strongTag(
            for: try await FileByteSource.open(atPath: path))

        // In-place rewrite: same inode, same length, mtime forged back to
        // the same second — every field of the WEAK identity collides on
        // purpose. Only ctime (kernel-set, unforgeable) distinguishes the
        // two, which is why it is part of the cache key: without it this
        // cache would serve the old digest as a STRONG validator for new
        // bytes, and a resumed download would stitch AAAA onto BBBB.
        try Data("BBBB".utf8).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: path)
        let secondTag = try await cache.strongTag(
            for: try await FileByteSource.open(atPath: path))
        #expect(firstTag != secondTag)
    }
}

@Suite("download disposition")
struct DownloadDispositionTests {

    @Test("plain ASCII names need only the fallback form")
    func ascii() {
        #expect(
            ContentDescriptor.attachmentDisposition(filename: "report.pdf")
                == #"attachment; filename="report.pdf""#)
    }

    @Test("non-ASCII names carry the RFC 8187 extended form")
    func unicode() {
        let disposition = ContentDescriptor.attachmentDisposition(filename: "résumé.pdf")
        #expect(disposition.contains(#"filename="r_sum_.pdf""#))
        #expect(disposition.contains("filename*=UTF-8''r%C3%A9sum%C3%A9.pdf"))
    }

    @Test("header injection cannot reach the wire")
    func injection() {
        let hostile = "evil\r\nSet-Cookie: pwned=1\".pdf"
        let disposition = ContentDescriptor.attachmentDisposition(filename: hostile)
        #expect(!disposition.contains("\r"))
        #expect(!disposition.contains("\n"))
        // The quoted fallback contains no unescaped quote that could close
        // the parameter early.
        let fallbackPart = disposition.split(separator: ";")[1]
        #expect(!fallbackPart.dropFirst(11).dropLast().contains("\""))
    }

    @Test("the descriptor helper lands the header in extraHeaders")
    func descriptorIntegration() {
        let descriptor = ContentDescriptor(source: DataByteSource(Data("x".utf8)))
            .download(filename: "export.csv")
        #expect(
            descriptor.extraHeaders[.contentDisposition]
                == #"attachment; filename="export.csv""#)
    }
}
