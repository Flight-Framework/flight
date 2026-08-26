import Foundation
import FlightWeb
import Testing

@Suite("FileByteSource")
struct FileByteSourceTests {

    private func withTemporaryDirectory<T>(
        _ body: (URL) async throws -> T
    ) async throws -> T {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("flight-fbs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        return try await body(directory)
    }

    @Test("reads a whole file, and slices of it, byte-for-byte")
    func readsCorrectly() async throws {
        try await withTemporaryDirectory { directory in
            let content = Data((0..<100_000).map { UInt8($0 % 251) })
            let path = directory.appendingPathComponent("blob.bin").path
            try content.write(to: URL(fileURLWithPath: path))

            let source = try await FileByteSource.open(atPath: path)
            #expect(source.count == 100_000)

            var whole = Data()
            // A chunk size that does not divide the file evenly, on purpose.
            for try await chunk in source.chunks(in: 0..<source.count, chunkSize: 4_099) {
                whole.append(chunk)
            }
            #expect(whole == content)

            var slice = Data()
            for try await chunk in source.chunks(in: 500..<1_500, chunkSize: 256) {
                slice.append(chunk)
            }
            #expect(slice == content.subdata(in: 500..<1_500))
        }
    }

    @Test("metadata comes from the open descriptor and feeds a stable validator")
    func metadataAndValidator() async throws {
        try await withTemporaryDirectory { directory in
            let path = directory.appendingPathComponent("asset.css").path
            try Data("body{}".utf8).write(to: URL(fileURLWithPath: path))

            let first = try await FileByteSource.open(atPath: path)
            let again = try await FileByteSource.open(atPath: path)
            #expect(EntityTag.file(first) == EntityTag.file(again), "unchanged file, same tag")
            #expect(EntityTag.file(first).isWeak, "mtime+identity is honest as weak")

            // Rewrite with different content of the same length: same size,
            // but mtime (nanosecond) and possibly inode move — the tag must.
            // A sleep-free way to guarantee mtime motion: set it explicitly.
            try Data("html{}".utf8).write(to: URL(fileURLWithPath: path))
            try FileManager.default.setAttributes(
                [.modificationDate: first.modificationDate.addingTimeInterval(2)],
                ofItemAtPath: path)
            let changed = try await FileByteSource.open(atPath: path)
            #expect(EntityTag.file(first) != EntityTag.file(changed), "changed file, new tag")
        }
    }

    @Test("a file truncated after open fails the stream loudly, never silently short")
    func truncationThrows() async throws {
        try await withTemporaryDirectory { directory in
            let path = directory.appendingPathComponent("shrinking.bin").path
            try Data(repeating: 7, count: 10_000).write(to: URL(fileURLWithPath: path))

            let source = try await FileByteSource.open(atPath: path)
            #expect(source.count == 10_000)

            // Truncate underneath the open descriptor — the exact TOCTOU
            // every stat-then-open server silently mangles into a short body
            // under an already-sent Content-Length.
            try Data(repeating: 7, count: 100).write(to: URL(fileURLWithPath: path))

            var delivered = 0
            await #expect(throws: ByteSourceError.self) {
                for try await chunk in source.chunks(in: 0..<10_000, chunkSize: 4_096) {
                    delivered += chunk.count
                }
            }
            #expect(delivered < 10_000, "the stream must not fabricate the missing bytes")
        }
    }

    @Test("a directory is refused as not-a-file")
    func directoryRefused() async throws {
        try await withTemporaryDirectory { directory in
            await #expect(throws: ByteSourceError.notAFile(directory.path)) {
                _ = try await FileByteSource.open(atPath: directory.path)
            }
        }
    }

    @Test("a missing path surfaces the errno, not a crash")
    func missingPath() async throws {
        try await withTemporaryDirectory { directory in
            let path = directory.appendingPathComponent("absent").path
            do {
                _ = try await FileByteSource.open(atPath: path)
                Issue.record("expected open to throw")
            } catch let error as ByteSourceError {
                guard case .io(let operation, let code) = error else {
                    Issue.record("expected .io, got \(error)")
                    return
                }
                #expect(operation.contains("open"))
                #expect(code == ENOENT)
            }
        }
    }

    @Test("noFollowLeaf refuses a symlinked leaf")
    func noFollowLeaf() async throws {
        try await withTemporaryDirectory { directory in
            let target = directory.appendingPathComponent("real.txt")
            try Data("secret".utf8).write(to: target)
            let link = directory.appendingPathComponent("link.txt")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

            // Without the option the link resolves…
            let followed = try await FileByteSource.open(atPath: link.path)
            #expect(followed.count == 6)

            // …with it, the open is refused at the syscall — closing the race
            // between any path-level check and this open.
            await #expect(throws: ByteSourceError.self) {
                _ = try await FileByteSource.open(atPath: link.path, options: [.noFollowLeaf])
            }
        }
    }

    @Test("an empty file serves an empty stream without error")
    func emptyFile() async throws {
        try await withTemporaryDirectory { directory in
            let path = directory.appendingPathComponent("empty").path
            try Data().write(to: URL(fileURLWithPath: path))
            let source = try await FileByteSource.open(atPath: path)
            #expect(source.count == 0)
            var chunks = 0
            for try await _ in source.chunks(in: 0..<0, chunkSize: 1_024) { chunks += 1 }
            #expect(chunks == 0)
        }
    }

    @Test("serveContent over a real file: 206 slice and 304 revalidation end to end")
    func serveContentOverRealFile() async throws {
        try await withTemporaryDirectory { directory in
            let content = Data("0123456789".utf8)
            let path = directory.appendingPathComponent("digits.txt").path
            try content.write(to: URL(fileURLWithPath: path))

            let source = try await FileByteSource.open(atPath: path)
            let descriptor = ContentDescriptor.file(source, contentType: "text/plain")

            let ranged = serveContent(
                for: Request(method: .get, path: "/d", headers: [.range: "bytes=-3"]),
                descriptor)
            #expect(ranged.status == .partialContent)
            #expect(try await ranged.collectedBody() == Data("789".utf8))

            let etag = ranged.headers[.eTag]
            let revalidated = serveContent(
                for: Request(method: .get, path: "/d", headers: [.ifNoneMatch: etag ?? ""]),
                descriptor)
            #expect(revalidated.status == .notModified)
        }
    }
}
