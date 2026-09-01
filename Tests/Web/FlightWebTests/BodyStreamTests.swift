import FlightCore
import FlightWeb
import FlightWebTesting
import Foundation
import HTTPTypes
import Testing

// Streaming request bodies, in-process: the macro records the mode in the
// route table, dispatch answers it like acceptsUpgrade, and a handler's
// `body: RequestBodyStream` receives live chunks. The wire half — the
// transport actually not buffering — lives in FlightTransportTests.

@Controller
struct StreamFixtureController {
    /// The single macro change of the phase, exercised: this route must be
    /// recorded as streaming-bodied with its cap.
    @PostRoute("/ingest", maxBodyBytes: 1_000_000)
    func ingest(_ context: RequestContext, body: RequestBodyStream) async throws -> String {
        var total = 0
        var chunks = 0
        for try await chunk in body.chunks {
            total += chunk.count
            chunks += 1
        }
        return "chunks:\(chunks) bytes:\(total) expected:\(body.expectedBytes.map(String.init) ?? "-")"
    }

    /// A buffered route with only a cap override — no streaming.
    @PostRoute("/bounded", maxBodyBytes: 16)
    func bounded(_ context: RequestContext, body: Data) -> String {
        "got:\(body.count)"
    }
}

private struct StreamModule: FlightModule {
    func configure(_ container: Container) throws {
        try StreamFixtureController._flightRegister(container)
        // The wiring-defect case: a handler that wants a stream on a route
        // whose table entry says buffered.
        container.registerRoute(.post, "/mismatched", source: "StreamModule") { context in
            _ = try FlightWeb.decodeRequestBody(RequestBodyStream.self, from: context)
            return .text("unreachable")
        }
    }
}

@Suite("streaming request bodies — in process")
struct BodyStreamTests {

    private func container() throws -> Container {
        try TestContainer.build { StreamModule() }
    }

    @Test("the macro records streaming mode and the cap in the route table")
    func routeTableRecordsBodyMode() throws {
        let routes = try container().collectRoutes()
        let ingest = try #require(routes.first { $0.path == "/ingest" })
        #expect(ingest.bodyMode == .streaming(maxBytes: 1_000_000))

        let bounded = try #require(routes.first { $0.path == "/bounded" })
        #expect(bounded.bodyMode == .buffered(maxBytes: 16))
    }

    @Test("dispatch answers bodyMode from the table, like acceptsUpgrade")
    func dispatchAnswersBodyMode() throws {
        let dispatch = try DispatchBuilder.build(container: container())
        #expect(
            dispatch.bodyMode(Request(method: .post, path: "/ingest"))
                == .streaming(maxBytes: 1_000_000))
        #expect(
            dispatch.bodyMode(Request(method: .post, path: "/no-such"))
                == .buffered(maxBytes: nil))
    }

    @Test("a handler receives the chunks exactly as they arrive")
    func chunksArriveLive() async throws {
        let client = try TestClient(container: container())
        let response = await client.post(
            "/ingest",
            bodyChunks: [Data("abc".utf8), Data("defgh".utf8), Data("i".utf8)])
        #expect(response.bodyText == "chunks:3 bytes:9 expected:9")
    }

    @Test("a mid-stream error reaches the handler as a thrown error, rendered honestly")
    func midStreamError() async throws {
        let client = try TestClient(container: container())
        var request = Request(method: .post, path: "/ingest")
        let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        continuation.yield(Data("partial".utf8))
        continuation.finish(throwing: BodyStreamLimitError(limit: 7))
        request.bodyStream = RequestBodyStream(expectedBytes: nil, chunks: stream)
        let response = await client.execute(request)
        #expect(response.status == .contentTooLarge)
    }

    @Test("a streaming handler on a buffered delivery is a 500, not a hang")
    func wiringMismatchIsLoud() async throws {
        let client = try TestClient(container: container())
        let response = await client.post("/mismatched", body: Data("buffered".utf8))
        #expect(response.status == .internalServerError)
    }

    @Test("multipart parses over the live stream — B and C composed")
    func multipartOverStream() async throws {
        struct UploadModule: FlightModule {
            func configure(_ container: Container) throws {
                container.registerRoute(
                    .post, "/upload", source: "UploadModule",
                    bodyMode: .streaming(maxBytes: nil)
                ) { context in
                    var summary: [String] = []
                    for try await part in try context.request.multipart() {
                        if part.filename != nil {
                            var bytes = 0
                            for try await chunk in part.body { bytes += chunk.count }
                            summary.append("\(part.name)=file(\(bytes))")
                        } else {
                            summary.append("\(part.name)=\(try await part.text())")
                        }
                    }
                    return .text(summary.joined(separator: ";"))
                }
            }
        }
        let boundary = "----seam"
        let wire = Data(
            ("--\(boundary)\r\n"
                + "Content-Disposition: form-data; name=\"title\"\r\n\r\n"
                + "hello\r\n"
                + "--\(boundary)\r\n"
                + "Content-Disposition: form-data; name=\"doc\"; filename=\"a.bin\"\r\n"
                + "Content-Type: application/octet-stream\r\n\r\n"
                + String(repeating: "z", count: 10_000) + "\r\n"
                + "--\(boundary)--").utf8)
        let client = try TestClient(container: TestContainer.build { UploadModule() })
        // Delivered in awkward 1KiB chunks — boundaries straddle seams.
        let chunks = stride(from: 0, to: wire.count, by: 1024).map {
            Data(wire[$0..<min($0 + 1024, wire.count)])
        }
        let response = await client.post(
            "/upload",
            headers: [.contentType: "multipart/form-data; boundary=\(boundary)"],
            bodyChunks: chunks)
        #expect(response.bodyText == "title=hello;doc=file(10000)")
    }
}
