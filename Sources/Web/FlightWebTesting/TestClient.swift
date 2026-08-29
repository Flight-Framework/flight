import FlightCore
import FlightWeb
import Foundation
import HTTPTypes
import Logging

/// Drives the full Flight Web pipeline — user middleware, routing, encoding,
/// scope-per-request, error mapping — entirely in process, no socket (§7).
///
///     let container = try TestContainer.build { AppModule() }
///     let client = try TestClient(container: container)
///     let response = try await client.get("/users/1")
///     #expect(response.status == .ok)
///
/// For upgrade routes, `webSocket(_:)` performs the in-process equivalent of
/// the 101 handshake and returns the client side of a connected pair.
public struct TestClient: Sendable {
    public let dispatch: Dispatch

    /// The wire format the application under test is configured for.
    ///
    /// The JSON helpers used a fresh default `JSONEncoder`/`JSONDecoder`, so
    /// a suite testing an app with `web.json.key-strategy: snake-case` got a
    /// 400 from `post(json:)` and a decode failure from `decodeJSON` — with
    /// nothing anywhere pointing at the format mismatch, on a client whose
    /// whole promise is that it drives the real pipeline.
    public let coders: WebCoders

    /// Builds dispatch from a frozen container, exactly as `FlightWebModule`
    /// would at service start (route-table validation included).
    public init(container: Container) throws {
        var logger = Logger(label: "flight.web.test-client")
        logger.logLevel = .critical
        self.dispatch = try DispatchBuilder.build(container: container, logger: logger)
        self.coders = (try? container.resolve(WebCoders.self)) ?? WebCoders.default
    }

    /// Wraps an existing dispatch closure (for transport-free harnesses).
    ///
    /// - Parameter coders: The app's wire format, when the harness knows it.
    ///   There is no container to read it from here, so it defaults to the
    ///   package default.
    public init(dispatch: Dispatch, coders: WebCoders = .default) {
        self.dispatch = dispatch
        self.coders = coders
    }

    // MARK: - Requests

    public func execute(_ request: Request) async -> Response {
        await dispatch(request)
    }

    public func get(_ path: String, headers: HTTPFields = [:]) async -> Response {
        await execute(Request(method: .get, path: path, headers: headers))
    }

    public func post(_ path: String, headers: HTTPFields = [:], body: Data = Data()) async -> Response {
        await execute(Request(method: .post, path: path, headers: headers, body: body))
    }

    public func post(_ path: String, headers: HTTPFields = [:], json value: some Encodable) async throws -> Response {
        await execute(Request(method: .post, path: path, headers: headers, body: try coders.jsonEncoder.encode(value)))
    }

    public func put(_ path: String, headers: HTTPFields = [:], json value: some Encodable) async throws -> Response {
        await execute(Request(method: .put, path: path, headers: headers, body: try coders.jsonEncoder.encode(value)))
    }

    /// PATCH, which is what a partial update is: the verb a changeset-backed
    /// endpoint uses, and the one this client was missing.
    public func patch(_ path: String, headers: HTTPFields = [:], body: Data = Data()) async -> Response {
        await execute(Request(method: .patch, path: path, headers: headers, body: body))
    }

    public func patch(_ path: String, headers: HTTPFields = [:], json value: some Encodable) async throws -> Response {
        await execute(Request(method: .patch, path: path, headers: headers, body: try coders.jsonEncoder.encode(value)))
    }

    public func delete(_ path: String, headers: HTTPFields = [:]) async -> Response {
        await execute(Request(method: .delete, path: path, headers: headers))
    }

    // MARK: - WebSocket (§6.1, in process)

    public enum TestClientError: Error, CustomStringConvertible {
        case notAnUpgrade(HTTPResponse.Status)

        public var description: String {
            switch self {
            case .notAnUpgrade(let status):
                return "Expected an upgrade response, got \(status)."
            }
        }
    }

    /// Dispatches an upgrade request to `path`; on `.upgrade`, wires an
    /// in-memory connection pair, runs the server handler in a child task,
    /// and returns the client end. Closing the client end (or the handler
    /// returning) tears the session down.
    public func webSocket(
        _ path: String,
        headers: HTTPFields = [:]
    ) async throws -> InMemoryWebSocket {
        var upgradeHeaders = headers
        upgradeHeaders[.connection] = "Upgrade"
        upgradeHeaders[.upgrade] = "websocket"
        upgradeHeaders[.secWebSocketKey] = "dGhlIHNhbXBsZSBub25jZQ=="
        upgradeHeaders[.secWebSocketVersion] = "13"

        let response = await execute(Request(method: .get, path: path, headers: upgradeHeaders))
        guard case .upgrade(.webSocket(let upgrade)) = response else {
            throw TestClientError.notAnUpgrade(response.status)
        }

        let (serverEnd, client) = InMemoryWebSocket.makeConnectedPair()
        let serverTask = Task {
            do {
                try await upgrade.run(serverEnd)
            } catch {
                // Handler failure closes the session; the test observes the
                // stream ending rather than a server-side crash.
            }
            client.finishFromServer()
        }
        // Cancelled when the client goes, not only when `close()` is called:
        // a test that drops its client without closing left this task parked
        // on the frame stream forever, one leaked task per such test.
        client.cancelServerTaskOnDeinit()
        client.attach(serverTask: serverTask)
        return client
    }
}

extension TestClient {
    /// Decodes a response body with the application's configured decoder.
    public func decodeJSON<T: Decodable>(
        _ type: T.Type = T.self, from response: Response
    ) throws -> T {
        try coders.jsonDecoder.decode(type, from: response.bodyData ?? Data())
    }
}

// MARK: - Response test accessors

extension TestClient {
    /// Executes a POST whose body arrives as a live chunk stream — the
    /// in-process way to drive a `body: RequestBodyStream` route. Chunks
    /// are delivered exactly as given, one yield each.
    public func post(
        _ path: String, headers: HTTPFields = [:], bodyChunks: [Data]
    ) async -> Response {
        var request = Request(method: .post, path: path, headers: headers)
        let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        for chunk in bodyChunks {
            continuation.yield(chunk)
        }
        continuation.finish()
        request.bodyStream = RequestBodyStream(
            expectedBytes: Int64(bodyChunks.reduce(0) { $0 + $1.count }),
            chunks: stream)
        return await execute(request)
    }
}

extension Response {
    /// Decodes a `.fixed` JSON body with the package's default decoder.
    ///
    /// Prefer ``FlightWebTesting/TestClient/decodeJSON(_:from:)`` when the
    /// application configures its wire format: this overload cannot know
    /// about it, which is how a snake-case app's responses failed to decode
    /// here with nothing pointing at why.
    public func decodeJSON<T: Decodable>(_ type: T.Type = T.self) throws -> T {
        try WebCoders.default.jsonDecoder.decode(type, from: bodyData ?? Data())
    }

    /// UTF-8 rendering of a `.fixed` body ("" for streaming/upgrade).
    public var bodyText: String {
        String(decoding: bodyData ?? Data(), as: UTF8.self)
    }

    /// Collects a `.streaming` body to completion (test-side; a real
    /// transport never buffers, §6.2).
    public func collectStreamingBody(maxBytes: Int = 1 << 22) async -> Data {
        guard case .streaming(_, _, let stream) = self else { return bodyData ?? Data() }
        var collected = Data()
        for await chunk in stream {
            collected.append(chunk)
            if collected.count >= maxBytes { break }
        }
        return collected
    }

    /// Collects any body shape to completion — the test-side equivalent of
    /// what a transport writes to the wire. `.fixed` returns its data,
    /// `.streaming` drains, `.file` reads the response's declared range from
    /// its source, `.upgrade` is empty.
    public func collectedBody(maxBytes: Int = 1 << 22) async throws -> Data {
        switch self {
        case .fixed(_, _, let body):
            return body
        case .streaming:
            return await collectStreamingBody(maxBytes: maxBytes)
        case .file(let file):
            var collected = Data()
            for try await chunk in file.source.chunks(in: file.range, chunkSize: file.chunkSize) {
                collected.append(chunk)
                if collected.count >= maxBytes { break }
            }
            return collected
        case .upgrade:
            return Data()
        }
    }
}
