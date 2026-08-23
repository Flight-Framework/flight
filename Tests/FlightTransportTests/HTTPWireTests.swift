import Foundation
import NIOCore
import Testing

/// Real-socket HTTP round-trips against a bound `FlightTransport` (§5.2).
@Suite("FlightTransport HTTP wire behavior", .serialized)
struct HTTPWireTests {

    @Test func fixedResponseRoundTrip() async throws {
        try await withRunningServer { port in
            try await RawSocketClient.withConnection(port: port) { session in
                try await session.send(
                    "GET /hello HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
                )
                let response = try await session.readToEnd()
                #expect(response.hasPrefix("HTTP/1.1 200 OK\r\n"))
                #expect(response.lowercased().contains("content-length: 5"))
                #expect(response.lowercased().contains("x-request-id:"))
                #expect(response.hasSuffix("\r\n\r\nhello"))
            }
        }
    }

    @Test func jsonPostRoundTrip() async throws {
        try await withRunningServer { port in
            try await RawSocketClient.withConnection(port: port) { session in
                let body = #"{"name":"flight"}"#
                try await session.send(
                    "POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\n"
                        + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                )
                let response = try await session.readToEnd()
                #expect(response.hasPrefix("HTTP/1.1 200 OK\r\n"))
                #expect(response.contains(#""name":"flight""#))
            }
        }
    }

    @Test func unknownRouteIs404() async throws {
        try await withRunningServer { port in
            try await RawSocketClient.withConnection(port: port) { session in
                try await session.send(
                    "GET /nope HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
                )
                let response = try await session.readToEnd()
                #expect(response.hasPrefix("HTTP/1.1 404 Not Found\r\n"))
            }
        }
    }

    @Test func keepAliveServesSequentialRequests() async throws {
        try await withRunningServer { port in
            try await RawSocketClient.withConnection(port: port) { session in
                try await session.send("GET /hello HTTP/1.1\r\nHost: localhost\r\n\r\n")
                let first = try await session.readUntil("hello")
                #expect(first.contains("HTTP/1.1 200 OK"))

                try await session.send(
                    "GET /hello HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
                )
                let both = try await session.readToEnd()
                #expect(both.components(separatedBy: "HTTP/1.1 200 OK").count == 3)
            }
        }
    }

    @Test func headSuppressesBodyButKeepsContentLength() async throws {
        try await withRunningServer { port in
            try await RawSocketClient.withConnection(port: port) { session in
                try await session.send(
                    "HEAD /hello HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
                )
                let response = try await session.readToEnd()
                #expect(response.hasPrefix("HTTP/1.1 200 OK\r\n"))
                #expect(response.lowercased().contains("content-length: 5"))
                #expect(response.hasSuffix("\r\n\r\n"))
            }
        }
    }

    @Test func wrongMethodIs405WithAllow() async throws {
        try await withRunningServer { port in
            try await RawSocketClient.withConnection(port: port) { session in
                try await session.send(
                    "DELETE /hello HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
                )
                let response = try await session.readToEnd()
                #expect(response.hasPrefix("HTTP/1.1 405 Method Not Allowed\r\n"))
                #expect(response.lowercased().contains("allow: get, head"))
            }
        }
    }

    @Test func oversizedBodyIs413() async throws {
        try await withRunningServer(maxRequestBodyBytes: 64) { port in
            try await RawSocketClient.withConnection(port: port) { session in
                let big = String(repeating: "x", count: 512)
                try await session.send(
                    "POST /echo HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n"
                        + "Content-Length: \(big.utf8.count)\r\n\r\n\(big)"
                )
                let response = try await session.readToEnd()
                #expect(response.hasPrefix("HTTP/1.1 413 "))
            }
        }
    }

    @Test func sseStreamsChunkedEvents() async throws {
        try await withRunningServer { port in
            try await RawSocketClient.withConnection(port: port) { session in
                try await session.send(
                    "GET /sse HTTP/1.1\r\nHost: localhost\r\n\r\n"
                )
                // The first event must arrive before the stream is complete —
                // proof the body is written as produced, not buffered (§6.2).
                let head = try await session.readUntil("data: first\n\n")
                #expect(head.contains("HTTP/1.1 200 OK"))
                #expect(head.lowercased().contains("transfer-encoding: chunked"))
                #expect(head.lowercased().contains("content-type: text/event-stream"))
                #expect(!head.contains("data: second"))

                let rest = try await session.readUntil("data: second\n\n")
                #expect(rest.contains("event: tick\ndata: second"))
            }
        }
    }

    @Test func plainRequestToUpgradeRouteIs426() async throws {
        try await withRunningServer { port in
            try await RawSocketClient.withConnection(port: port) { session in
                try await session.send(
                    "GET /ws/lobby HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
                )
                let response = try await session.readToEnd()
                #expect(response.hasPrefix("HTTP/1.1 426 Upgrade Required\r\n"))
            }
        }
    }

    @Test func webSocketHandshakeToUnknownPathIsRefused() async throws {
        try await withRunningServer { port in
            try await RawSocketClient.withConnection(port: port) { session in
                try await session.send(
                    "GET /nope HTTP/1.1\r\nHost: localhost\r\n"
                        + "Connection: Upgrade\r\nUpgrade: websocket\r\n"
                        + "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"
                )
                // Routing/middleware refused the upgrade (no route matched).
                // HummingbirdCore answers every refused upgrade with its own
                // 400 + connection close (README delta 8); the routed status
                // is asserted at the dispatch level by the TestClient suite.
                let response = try await session.readToEnd()
                #expect(response.hasPrefix("HTTP/1.1 400 Bad Request\r\n"))
                #expect(response.lowercased().contains("connection: close"))
            }
        }
    }

    @Test("an upgrade handshake at an ordinary route runs no handler")
    func webSocketHandshakeDoesNotRunHTTPHandler() async throws {
        // Below the fix this looked identical from the client's side — a 400
        // either way. What differed is what the server did first: it
        // dispatched the request, ran the matched GET handler and every side
        // effect it had, then discarded a response it could not use. Any GET
        // route was reachable by attaching upgrade headers, no credentials
        // required. Only the counter can tell the two apart.
        WireSideEffect.reset()
        try await withRunningServer { port in
            try await RawSocketClient.withConnection(port: port) { session in
                try await session.send(
                    "GET /counted HTTP/1.1\r\nHost: localhost\r\n"
                        + "Connection: Upgrade\r\nUpgrade: websocket\r\n"
                        + "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
                        + "Sec-WebSocket-Version: 13\r\n\r\n"
                )
                let response = try await session.readToEnd()
                #expect(response.hasPrefix("HTTP/1.1 400 Bad Request\r\n"))
            }
            #expect(
                WireSideEffect.count.withLock { $0 } == 0,
                "the GET handler must not run for an upgrade request at a non-upgrade route")

            // The same route still serves ordinary GETs.
            try await RawSocketClient.withConnection(port: port) { session in
                try await session.send(
                    "GET /counted HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
                )
                let response = try await session.readToEnd()
                #expect(response.contains("counted"))
            }
            #expect(WireSideEffect.count.withLock { $0 } == 1)
        }
    }

    @Test func expectContinueIsAnswered() async throws {
        try await withRunningServer { port in
            try await RawSocketClient.withConnection(port: port) { session in
                let body = #"{"name":"continue"}"#
                try await session.send(
                    "POST /echo HTTP/1.1\r\nHost: localhost\r\nExpect: 100-continue\r\n"
                        + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
                )
                let interim = try await session.readUntil("HTTP/1.1 100 Continue\r\n\r\n")
                #expect(interim.contains("HTTP/1.1 100 Continue"))
                try await session.send(body)
                let final = try await session.readToEnd()
                #expect(final.contains("HTTP/1.1 200 OK"))
                #expect(final.contains(#""name":"continue""#))
            }
        }
    }
}
