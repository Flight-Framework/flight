import FlightWeb
import FlightWebTesting
import Foundation
import HTTPTypes
import Testing

@Suite("Response & ResponseEncodable (§4, §6.2)")
struct ResponseTests {

    struct UserResponse: Codable, ResponseEncodable, Equatable {
        let id: Int
        let name: String
    }

    @Test func encodableTypesRenderAsJSON200() throws {
        let response = try encodeResponse(UserResponse(id: 1, name: "ada"), for: .mock())
        #expect(response.status == .ok)
        #expect(response.headers[.contentType]?.contains("application/json") == true)
        #expect(try response.decodeJSON(UserResponse.self) == UserResponse(id: 1, name: "ada"))
    }

    @Test func responsePassesThroughUntouched() throws {
        let teapot = HTTPResponse.Status(code: 418)
        let original = Response.status(teapot)
        let encoded = try encodeResponse(original, for: .mock())
        #expect(encoded.status == teapot)
    }

    @Test func stringIsPlainText() throws {
        let response = try encodeResponse("hello", for: .mock())
        #expect(response.status == .ok)
        #expect(response.headers[.contentType]?.contains("text/plain") == true)
        #expect(response.bodyText == "hello")
    }

    @Test func dataIsOctetStream() throws {
        let response = try encodeResponse(Data([1, 2, 3]), for: .mock())
        #expect(response.headers[.contentType] == "application/octet-stream")
        #expect(response.bodyData == Data([1, 2, 3]))
    }

    @Test func nilOptionalIs404() throws {
        let value: UserResponse? = nil
        let response = try encodeResponse(value, for: .mock())
        #expect(response.status == .notFound)
    }

    @Test func someOptionalUnwraps() throws {
        let value: UserResponse? = UserResponse(id: 2, name: "grace")
        let response = try encodeResponse(value, for: .mock())
        #expect(response.status == .ok)
    }

    @Test func arraysAndDictionariesAreJSON() throws {
        let list = try encodeResponse([UserResponse(id: 1, name: "a")], for: .mock())
        #expect(try list.decodeJSON([UserResponse].self).count == 1)
        let map = try encodeResponse(["count": 3], for: .mock())
        #expect(try map.decodeJSON([String: Int].self) == ["count": 3])
    }

    @Test func jsonHelperHonorsStatus() throws {
        let response = try Response.json(UserResponse(id: 1, name: "a"), status: .created)
        #expect(response.status == .created)
    }

    @Test func problemBodyShape() throws {
        struct Problem: Codable { let status: Int; let title: String; let detail: String? }
        let response = Response.problem(status: .notFound, message: "no such user")
        #expect(response.headers[.contentType] == "application/problem+json")
        let problem = try response.decodeJSON(Problem.self)
        #expect(problem.status == 404)
        #expect(problem.title == "Not Found")
        #expect(problem.detail == "no such user")
    }

    @Test("the pre-9457 shape is still available for clients that parse it")
    func simpleErrorBodyShape() throws {
        struct Simple: Codable { let status: Int; let error: String }
        let response = Response.problem(
            status: .notFound, message: "Not Found", render: SimpleErrorBody.render)
        #expect(response.headers[.contentType] == ContentType.json.rawValue)
        let simple = try response.decodeJSON(Simple.self)
        #expect(simple.status == 404)
        #expect(simple.error == "Not Found")
    }

    @Test func settingHeaderPreservesEverythingElse() {
        let response = Response.text("x").settingHeader(.xRequestID, "abc")
        #expect(response.headers[.xRequestID] == "abc")
        #expect(response.bodyText == "x")
        #expect(response.status == .ok)
    }

    @Test func upgradeStatusIs101() {
        struct NoopHandler: WebSocketUpgradeHandler {
            func handle(upgraded connection: WebSocketConnection, context: RequestContext) async throws {}
        }
        let response = Response.upgrade(handler: NoopHandler(), context: .mock())
        #expect(response.status == .switchingProtocols)
        #expect(response.bodyData == nil)
    }
}

@Suite("Streaming responses (§6.2)")
struct StreamingResponseTests {

    @Test func producesChunksInOrder() async {
        let response = Response.streaming(contentType: .text) { emit in
            emit.yield(Data("one".utf8))
            emit.yield(Data("two".utf8))
        }
        #expect(response.headers[.contentType]?.contains("text/plain") == true)
        let body = await response.collectStreamingBody()
        #expect(String(decoding: body, as: UTF8.self) == "onetwo")
    }

    @Test func producerIsCancelledWhenConsumerStops() async throws {
        let (cancelSignal, cancelContinuation) = AsyncStream<Void>.makeStream()
        let response = Response.streaming(contentType: .text) { emit in
            emit.yield(Data("first".utf8))
            do {
                while true {
                    try Task.checkCancellation()
                    try await Task.sleep(for: .milliseconds(10))
                    emit.yield(Data("more".utf8))
                }
            } catch {
                cancelContinuation.yield(())
                cancelContinuation.finish()
            }
        }
        guard case .streaming(_, _, let stream) = response else {
            Issue.record("expected streaming response")
            return
        }
        // Consume one chunk, then the consuming task is cancelled while
        // awaiting more — the transport's client-disconnect shape (a
        // cancelled write ends the write loop and the stream with it).
        let (firstChunk, firstChunkArrived) = AsyncStream<Void>.makeStream()
        let consumer = Task {
            for await _ in stream {
                firstChunkArrived.yield(())
                firstChunkArrived.finish()
            }
        }
        for await _ in firstChunk { break }
        consumer.cancel()
        await consumer.value
        // The producer must observe cancellation promptly.
        for await _ in cancelSignal { break }
    }
}

@Suite("Server-Sent Events (§6.2)")
struct ServerSentEventTests {

    @Test func encodesSingleLineData() {
        let event = ServerSentEvent(data: "hello", event: "greeting", id: "1")
        let text = String(decoding: event.encoded, as: UTF8.self)
        #expect(text == "event: greeting\nid: 1\ndata: hello\n\n")
    }

    @Test func multiLineDataBecomesMultipleDataFields() {
        let event = ServerSentEvent(data: "line1\nline2")
        let text = String(decoding: event.encoded, as: UTF8.self)
        #expect(text == "data: line1\ndata: line2\n\n")
    }

    @Test func retryRendersMilliseconds() {
        let event = ServerSentEvent(data: "x", retry: .seconds(2))
        let text = String(decoding: event.encoded, as: UTF8.self)
        #expect(text.contains("retry: 2000\n"))
    }

    @Test func fieldValuesCannotForgeExtraFields() {
        let event = ServerSentEvent(data: "x", event: "a\nevil: y", id: "1\r2")
        let text = String(decoding: event.encoded, as: UTF8.self)
        // The injected newlines are neutralized: no line may *start* a forged
        // field; the payload text itself survives inline.
        #expect(!text.split(separator: "\n").contains { $0.hasPrefix("evil:") })
        #expect(text.contains("event: a evil: y\n"))
        #expect(text.contains("id: 1 2\n"))
    }

    @Test func sseResponseHasEventStreamHeadersAndPayload() async {
        let response = Response.serverSentEvents { events in
            events.send(data: "one", event: "tick")
            events.send(data: "two", event: "tick", id: "2")
            events.sendHeartbeat()
        }
        #expect(response.headers[.contentType]?.contains("text/event-stream") == true)
        #expect(response.headers[.cacheControl] == "no-cache")
        let body = String(decoding: await response.collectStreamingBody(), as: UTF8.self)
        #expect(body.contains("event: tick\ndata: one\n\n"))
        #expect(body.contains("id: 2\ndata: two\n\n"))
        #expect(body.contains(": keep-alive\n\n"))
    }
}

@Suite("Request parsing")
struct RequestTests {

    @Test func pathStripsQueryAndFragment() {
        let request = Request(path: "/users?x=1#frag")
        #expect(request.path == "/users")
        #expect(request.uri == "/users?x=1#frag")
    }

    @Test func queryItemsDecodeAndPreserveOrder() {
        let request = Request(path: "/search?q=swift%20flight&tag=a&tag=b&flag")
        #expect(request.queryParam("q") == "swift flight")
        #expect(request.queryItems.filter { $0.name == "tag" }.map(\.value) == ["a", "b"])
        #expect(request.queryParam("flag") == "")
        #expect(request.queryParam("missing") == nil)
    }

    @Test func plusDecodesAsSpaceInQuery() {
        let request = Request(path: "/search?q=a+b")
        #expect(request.queryParam("q") == "a b")
    }

    @Test func noQueryMeansNoItems() {
        #expect(Request(path: "/plain").queryItems.isEmpty)
    }
}
