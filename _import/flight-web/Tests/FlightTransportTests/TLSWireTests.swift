import FlightCore
import FlightTransport
import Foundation
import NIOSSL
import Testing

/// HTTPS end to end: a certificate generated for this run, a real handshake,
/// a real request over it.
@Suite("FlightTransport TLS")
struct TLSWireTests {

    /// Generates fresh material into a temporary directory for one test.
    private func withMaterial(
        _ body: (
            _ serverTLS: FlightTransportConfiguration.TLS,
            _ caRoots: String, _ clientChain: String, _ clientKey: String
        ) async throws -> Void
    ) async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("flight-tls-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let written = try TLSFixture.write(to: directory)
        try await body(
            FlightTransportConfiguration.TLS(
                certificateChainPath: written.serverChain,
                privateKeyPath: written.serverKey),
            written.caRoots, written.clientChain, written.clientKey)
    }

    @Test("a request over HTTPS round-trips")
    func httpsRoundTrip() async throws {
        try await withMaterial { serverTLS, caRoots, _, _ in
            try await withRunningServer(tls: serverTLS) { port in
                try await RawSocketClient.withTLSConnection(
                    port: port, trustRootsPath: caRoots
                ) { session in
                    try await session.send(
                        "GET /hello HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
                    let response = try await session.readToEnd()
                    #expect(response.hasPrefix("HTTP/1.1 200 OK\r\n"))
                    #expect(response.hasSuffix("\r\n\r\nhello"))
                }
            }
        }
    }

    @Test("a plaintext request to a TLS listener does not get served")
    func plaintextAgainstTLSIsRefused() async throws {
        try await withMaterial { serverTLS, _, _, _ in
            try await withRunningServer(tls: serverTLS) { port in
                try await RawSocketClient.withConnection(port: port) { session in
                    try await session.send(
                        "GET /hello HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
                    // The server sees a malformed ClientHello and drops the
                    // connection; what must never happen is a 200 in cleartext.
                    let response = try? await session.readToEnd()
                    #expect(!(response ?? "").contains("hello"))
                }
            }
        }
    }

    @Test("mutual TLS: a trusted client certificate is served")
    func mutualTLSAccepted() async throws {
        try await withMaterial { serverTLS, caRoots, clientChain, clientKey in
            var mutual = serverTLS
            mutual.trustRootsPath = caRoots
            mutual.clientAuthentication = .require

            try await withRunningServer(tls: mutual) { port in
                try await RawSocketClient.withTLSConnection(
                    port: port,
                    trustRootsPath: caRoots,
                    clientCertificatePath: clientChain,
                    clientKeyPath: clientKey
                ) { session in
                    try await session.send(
                        "GET /hello HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
                    let response = try await session.readToEnd()
                    #expect(response.hasPrefix("HTTP/1.1 200 OK\r\n"))
                }
            }
        }
    }

    @Test("mutual TLS: a client presenting no certificate is rejected")
    func mutualTLSRejectsAnonymous() async throws {
        try await withMaterial { serverTLS, caRoots, _, _ in
            var mutual = serverTLS
            mutual.trustRootsPath = caRoots
            mutual.clientAuthentication = .require

            try await withRunningServer(tls: mutual) { port in
                // Trusts the server, presents nothing of its own.
                await #expect(throws: (any Error).self) {
                    try await RawSocketClient.withTLSConnection(
                        port: port, trustRootsPath: caRoots
                    ) { session in
                        try await session.send(
                            "GET /hello HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
                        let response = try await session.readToEnd()
                        #expect(!response.contains("hello"), "an anonymous client must not be served")
                    }
                }
            }
        }
    }

    @Test("a client that does not trust the CA fails the handshake")
    func untrustedServerCertificateFails() async throws {
        try await withMaterial { serverTLS, _, _, _ in
            // A second, unrelated CA — the server's certificate does not chain to it.
            let otherDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("flight-tls-other-\(UUID().uuidString)")
            try FileManager.default.createDirectory(
                at: otherDirectory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: otherDirectory) }
            let other = try TLSFixture.write(to: otherDirectory)

            try await withRunningServer(tls: serverTLS) { port in
                await #expect(throws: (any Error).self) {
                    try await RawSocketClient.withTLSConnection(
                        port: port, trustRootsPath: other.caRoots
                    ) { session in
                        try await session.send("GET /hello HTTP/1.1\r\n\r\n")
                        _ = try await session.readToEnd()
                    }
                }
            }
        }
    }
}

/// The configuration surface, without standing a server up.
@Suite("TLS configuration")
struct TLSConfigurationTests {

    private func configuration(_ pairs: [String: String]) -> FlightCore.Configuration {
        FlightCore.Configuration(values: pairs)
    }

    @Test("no TLS keys means plaintext, not an error")
    func absentMeansPlaintext() throws {
        let transport = try FlightTransportConfiguration(configuration: configuration([:]))
        #expect(transport.tls == nil)
    }

    @Test("naming a certificate without a key fails at startup")
    func halfConfiguredIsAnError() throws {
        #expect(throws: TLSConfigurationError.self) {
            try FlightTransportConfiguration(
                configuration: configuration(["server.tls.certificate-chain-path": "/tmp/x.pem"]))
        }
        #expect(throws: TLSConfigurationError.self) {
            try FlightTransportConfiguration(
                configuration: configuration(["server.tls.private-key-path": "/tmp/x.key"]))
        }
    }

    @Test("both keys present enables TLS")
    func bothKeysEnableTLS() throws {
        let transport = try FlightTransportConfiguration(
            configuration: configuration([
                "server.tls.certificate-chain-path": "/tmp/fullchain.pem",
                "server.tls.private-key-path": "/tmp/privkey.pem",
            ]))
        #expect(transport.tls?.certificateChainPath == "/tmp/fullchain.pem")
        #expect(transport.tls?.clientAuthentication == FlightTransportConfiguration.TLS.ClientAuthentication.none)
    }

    @Test("an unknown client-authentication mode names the supported ones")
    func unknownClientAuthMode() throws {
        #expect(throws: TLSConfigurationError.self) {
            try FlightTransportConfiguration(
                configuration: configuration([
                    "server.tls.certificate-chain-path": "/tmp/fullchain.pem",
                    "server.tls.private-key-path": "/tmp/privkey.pem",
                    "server.tls.client-authentication": "mutual",
                ]))
        }
    }

    @Test("client authentication without trust roots is refused")
    func clientAuthNeedsRoots() throws {
        let tls = FlightTransportConfiguration.TLS(
            certificateChainPath: "/tmp/fullchain.pem",
            privateKeyPath: "/tmp/privkey.pem",
            clientAuthentication: .require)
        #expect(throws: TLSConfigurationError.self) {
            _ = try tls.nioConfiguration()
        }
    }

    @Test("an unreadable certificate names the path")
    func unreadableCertificateNamesPath() throws {
        let tls = FlightTransportConfiguration.TLS(
            certificateChainPath: "/nonexistent/fullchain.pem",
            privateKeyPath: "/nonexistent/privkey.pem")
        do {
            _ = try tls.nioConfiguration()
            Issue.record("expected a thrown error")
        } catch let error as TLSConfigurationError {
            #expect("\(error)".contains("/nonexistent/fullchain.pem"))
        }
    }
}
