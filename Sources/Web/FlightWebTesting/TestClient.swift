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

    /// Builds dispatch from a frozen container, exactly as `FlightWebModule`
    /// would at service start (route-table validation included).
    public init(container: Container) throws {
        var logger = Logger(label: "flight.web.test-client")
        logger.logLevel = .critical
        self.dispatch = try DispatchBuilder.build(container: container, logger: logger)
    }

    /// Wraps an existing dispatch closure (for transport-free harnesses).
    public init(dispatch: Dispatch) {
        self.dispatch = dispatch
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
        await execute(Request(method: .post, path: path, headers: headers, body: try JSONEncoder().encode(value)))
    }

    public func put(_ path: String, headers: HTTPFields = [:], json value: some Encodable) async throws -> Response {
        await execute(Request(method: .put, path: path, headers: headers, body: try JSONEncoder().encode(value)))
    }

    /// PATCH, which is what a partial update is: the verb a changeset-backed
    /// endpoint uses, and the one this client was missing.
    public func patch(_ path: String, headers: HTTPFields = [:], body: Data = Data()) async -> Response {
        await execute(Request(method: .patch, path: path, headers: headers, body: body))
    }

    public func patch(_ path: String, headers: HTTPFields = [:], json value: some Encodable) async throws -> Response {
        await execute(Request(method: .patch, path: path, headers: headers, body: try JSONEncoder().encode(value)))
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
        client.attach(serverTask: serverTask)
        return client
    }
}

// MARK: - Response test accessors

extension Response {
    /// Decodes a `.fixed` JSON body.
    public func decodeJSON<T: Decodable>(_ type: T.Type = T.self) throws -> T {
        try JSONDecoder().decode(type, from: bodyData ?? Data())
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
}
