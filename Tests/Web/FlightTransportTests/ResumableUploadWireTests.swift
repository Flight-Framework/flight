import FlightWeb
import Foundation
import NIOCore
import Synchronization
import Testing

/// The acceptance test for resumable uploads: a real socket, a real tus
/// exchange, and a connection **killed mid-transfer** — then a resume that
/// completes, with the assembled file compared byte for byte.
///
/// Everything else about uploads is checkable in process. This is not: the
/// whole feature exists for the moment a network dies partway through, and
/// nothing short of actually cutting a socket demonstrates that the bytes
/// already sent survive and the client is told exactly where to continue.
@Suite("resumable uploads over the wire", .serialized)
struct ResumableUploadWireTests {

    private func withUploadServer(
        _ body: @escaping @Sendable (_ port: Int, _ store: DiskUploadStore) async throws -> Void
    ) async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("flight-wire-uploads-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        // Flush every 64 KiB: small enough that an interruption lands
        // between durability points, as it would on a real slow link.
        let store = try DiskUploadStore(directory: directory, flushInterval: 64 << 10)
        WireModule.uploadStore.withLock { $0 = store }
        defer { WireModule.uploadStore.withLock { $0 = nil } }
        try await withRunningServer(maxRequestBodyBytes: 1 << 20) { port in
            try await body(port, store)
        }
    }

    /// Reads a full response head + body from a raw session.
    private func headerValue(_ response: String, _ name: String) -> String? {
        for line in response.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].lowercased() == name.lowercased() {
                return parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    @Test("an abandoned upload resumes from its true offset and reassembles exactly")
    func abandonedUploadResumes() async throws {
        try await withUploadServer { port, store in
            // Bounded chunk appends, which is what real tus clients do —
            // a browser cannot stream a request body over HTTP/1.1, so
            // tus-js-client uploads in chunks and resumes at chunk
            // granularity. "Interrupted" therefore means: the client sent
            // some chunks, went away mid-upload, and came back later
            // without remembering how far it got.
            let chunkSize = 64 << 10
            let total = 400_000
            // Position-dependent bytes: any misplacement shows up in the
            // final comparison instead of hiding behind repetition.
            let payload = Data((0..<total).map { UInt8(($0 &* 31 &+ 7) % 251) })

            var location = ""
            try await RawSocketClient.withConnection(port: port) { session in
                try await session.send(
                    "POST /uploads HTTP/1.1\r\nHost: localhost\r\nTus-Resumable: 1.0.0\r\n"
                        + "Upload-Length: \(total)\r\nConnection: close\r\n\r\n")
                let response = try await session.readToEnd()
                #expect(response.hasPrefix("HTTP/1.1 201 "))
                location = self.headerValue(response, "Location") ?? ""
            }
            #expect(location.hasPrefix("/uploads/"))
            let id = String(location.dropFirst("/uploads/".count))

            /// One append, each on its own connection as a real client does.
            let target = location
            @Sendable func append(from offset: Int, count: Int) async throws -> String {
                var result = ""
                try await RawSocketClient.withConnection(port: port) { session in
                    let slice = Data(payload[offset..<min(offset + count, total)])
                    try await session.send(
                        "PATCH \(target) HTTP/1.1\r\nHost: localhost\r\n"
                            + "Tus-Resumable: 1.0.0\r\n"
                            + "Content-Type: application/offset+octet-stream\r\n"
                            + "Upload-Offset: \(offset)\r\nContent-Length: \(slice.count)\r\n"
                            + "Connection: close\r\n\r\n")
                    try await session.sendBytes(slice)
                    result = try await session.readToEnd()
                }
                return result
            }

            // Two chunks land, then the client vanishes.
            #expect(try await append(from: 0, count: chunkSize).hasPrefix("HTTP/1.1 204 "))
            #expect(
                try await append(from: chunkSize, count: chunkSize)
                    .hasPrefix("HTTP/1.1 204 "))

            // It returns and asks where it got to, exactly as a resuming
            // client must — its own memory of the offset is untrustworthy.
            var resumeOffset = 0
            try await RawSocketClient.withConnection(port: port) { session in
                try await session.send(
                    "HEAD \(location) HTTP/1.1\r\nHost: localhost\r\nTus-Resumable: 1.0.0\r\n"
                        + "Connection: close\r\n\r\n")
                let response = try await session.readToEnd()
                #expect(response.hasPrefix("HTTP/1.1 200 "))
                #expect(self.headerValue(response, "Cache-Control") == "no-store")
                #expect(self.headerValue(response, "Upload-Length") == "\(total)")
                resumeOffset = Int(self.headerValue(response, "Upload-Offset") ?? "0") ?? 0
            }
            #expect(resumeOffset == 2 * chunkSize, "the server knows exactly what it has")

            // Resume to completion from the server's answer.
            var offset = resumeOffset
            while offset < total {
                let response = try await append(from: offset, count: chunkSize)
                #expect(response.hasPrefix("HTTP/1.1 204 "))
                offset = Int(self.headerValue(response, "Upload-Offset") ?? "0") ?? offset
            }
            #expect(offset == total)

            // The assembled file is the file that was sent. This is the
            // assertion the whole feature answers to: an upload that
            // survived an interruption is byte-identical, not merely the
            // right length.
            let info = try #require(try await store.info(id))
            #expect(info.isComplete)
            let source = try await store.readable(id)
            var assembled = Data()
            for try await chunk in source.chunks(in: 0..<source.count, chunkSize: 64 << 10) {
                assembled.append(chunk)
            }
            #expect(assembled.count == total)
            #expect(assembled == payload)
        }
    }

    @Test("a resumed append at a stale offset is refused over the wire, with the truth")
    func staleResumeRefusedOnTheWire() async throws {
        try await withUploadServer { port, _ in
            let payload = Data(repeating: 0x37, count: 5_000)
            var location = ""
            try await RawSocketClient.withConnection(port: port) { session in
                try await session.send(
                    "POST /uploads HTTP/1.1\r\nHost: localhost\r\nTus-Resumable: 1.0.0\r\n"
                        + "Upload-Length: \(payload.count)\r\nConnection: close\r\n\r\n")
                location = self.headerValue(try await session.readToEnd(), "Location") ?? ""
            }

            try await RawSocketClient.withConnection(port: port) { session in
                try await session.send(
                    "PATCH \(location) HTTP/1.1\r\nHost: localhost\r\nTus-Resumable: 1.0.0\r\n"
                        + "Content-Type: application/offset+octet-stream\r\n"
                        + "Upload-Offset: 0\r\nContent-Length: 2000\r\nConnection: close\r\n\r\n")
                try await session.sendBytes(payload.prefix(2_000))
                #expect(try await session.readToEnd().hasPrefix("HTTP/1.1 204 "))
            }

            // The client's acknowledgement was lost, so it retries from 0.
            // Applying that twice would duplicate 2000 bytes into the file.
            try await RawSocketClient.withConnection(port: port) { session in
                try await session.send(
                    "PATCH \(location) HTTP/1.1\r\nHost: localhost\r\nTus-Resumable: 1.0.0\r\n"
                        + "Content-Type: application/offset+octet-stream\r\n"
                        + "Upload-Offset: 0\r\nContent-Length: 2000\r\nConnection: close\r\n\r\n")
                try await session.sendBytes(payload.prefix(2_000))
                let response = try await session.readToEnd()
                #expect(response.hasPrefix("HTTP/1.1 409 "))
                #expect(
                    self.headerValue(response, "Upload-Offset") == "2000",
                    "the refusal must carry where the upload actually is")
            }
        }
    }

    @Test("OPTIONS discovery works over the wire")
    func discovery() async throws {
        try await withUploadServer { port, _ in
            try await RawSocketClient.withConnection(port: port) { session in
                try await session.send(
                    "OPTIONS /uploads HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
                let response = try await session.readToEnd()
                #expect(response.hasPrefix("HTTP/1.1 204 "))
                #expect(self.headerValue(response, "Tus-Version") == "1.0.0")
                #expect(
                    self.headerValue(response, "Tus-Extension")?.contains("creation") == true)
            }
        }
    }
}
