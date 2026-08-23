import FlightCore
import FlightWeb
import NIOSSL

/// `FlightTransport`'s settings, read from the app-wide Flight configuration
/// (flight.yaml / FLIGHT_* environment variables) under `server.*`:
///
///     server.host: 127.0.0.1
///     server.port: 8080
///     server.backlog: 256
///     server.max-request-body-bytes: 1048576
///     server.max-websocket-frame-bytes: 1048576
///
/// HTTPS is off until a certificate and key are named, and on as soon as
/// they are — there is no separate enable flag to forget:
///
///     server.tls.certificate-chain-path: /etc/tls/fullchain.pem
///     server.tls.private-key-path: /etc/tls/privkey.pem
///
/// Both are PEM. `certificate-chain-path` may hold a chain (leaf first);
/// serving only the leaf is the usual cause of "works in curl, fails in a
/// browser". Naming one without the other is a startup error rather than a
/// silent fall back to plaintext — a server that was meant to be HTTPS and
/// quietly is not is the worst of the three outcomes.
///
/// Mutual TLS, when the client must present a certificate too:
///
///     server.tls.trust-roots-path: /etc/tls/ca.pem
///     server.tls.client-authentication: require   # none | request | require
///
/// Terminating TLS at a reverse proxy or load balancer instead is an equally
/// supported deployment — leave these keys out and Flight serves plaintext
/// to the proxy.
///
/// Every key is optional; the defaults above apply. The memberwise
/// initializer exists for tests and embedders that bypass Flight Config.
public struct FlightTransportConfiguration: ServerTransportConfiguration {
    public var host: String
    public var port: Int
    public var backlog: Int
    /// Requests with bodies beyond this are answered 413 and the connection
    /// closed — enforced before dispatch ever runs.
    public var maxRequestBodyBytes: Int
    public var maxWebSocketFrameBytes: Int
    /// TLS settings, or nil to serve plaintext.
    public var tls: TLS?

    /// Invoked once the listening socket is bound, with the actual port —
    /// the seam that makes `port: 0` (ephemeral) usable in tests.
    public var onBound: (@Sendable (_ port: Int) -> Void)?

    /// What the transport needs to serve HTTPS.
    ///
    /// Held as file paths rather than parsed material so a misconfigured
    /// path fails at startup with the path in the message, and so the
    /// structure stays `Equatable` and printable without ever holding a
    /// private key in memory longer than the handshake setup needs it.
    public struct TLS: Sendable, Equatable {
        /// Whether the server asks the client for a certificate, and what it
        /// does when one is missing or untrusted.
        public enum ClientAuthentication: String, Sendable, Equatable, CaseIterable {
            /// Never ask. The default, and correct for a public API.
            case none
            /// Ask, but serve clients that decline or present an untrusted one.
            case request
            /// Ask, and reject the handshake unless a trusted certificate is
            /// presented — mutual TLS.
            case require
        }

        /// PEM, leaf certificate first, intermediates after.
        public var certificateChainPath: String
        /// PEM private key for the leaf certificate.
        public var privateKeyPath: String
        /// PEM roots used to verify client certificates. Required for
        /// `.request` and `.require`; the system trust store otherwise.
        public var trustRootsPath: String?
        public var clientAuthentication: ClientAuthentication

        public init(
            certificateChainPath: String,
            privateKeyPath: String,
            trustRootsPath: String? = nil,
            clientAuthentication: ClientAuthentication = .none
        ) {
            self.certificateChainPath = certificateChainPath
            self.privateKeyPath = privateKeyPath
            self.trustRootsPath = trustRootsPath
            self.clientAuthentication = clientAuthentication
        }

        /// Reads the PEM material and builds the NIO configuration.
        ///
        /// Throws rather than degrading: an unreadable certificate, an
        /// unparseable key, or client authentication demanded with no roots
        /// to verify against are all startup failures.
        public func nioConfiguration() throws -> TLSConfiguration {
            let chain: [NIOSSLCertificate]
            do {
                chain = try NIOSSLCertificate.fromPEMFile(certificateChainPath)
            } catch {
                throw TLSConfigurationError.unreadableCertificateChain(
                    path: certificateChainPath, underlying: error)
            }
            let key: NIOSSLPrivateKey
            do {
                key = try NIOSSLPrivateKey(file: privateKeyPath, format: .pem)
            } catch {
                throw TLSConfigurationError.unreadablePrivateKey(
                    path: privateKeyPath, underlying: error)
            }

            var configuration = TLSConfiguration.makeServerConfiguration(
                certificateChain: chain.map { .certificate($0) },
                privateKey: .privateKey(key))

            // NIOSSL's names read from a *client's* point of view, and mean
            // something different on a server. `.fullVerification` adds
            // hostname checking, which a client certificate has no hostname to
            // satisfy — using it here rejects every client, valid or not. Both
            // it and `.noHostnameVerification` also make a certificate
            // mandatory. The "ask, verify if offered, serve anyway" mode is
            // spelled `.optionalVerification`.
            switch clientAuthentication {
            case .none:
                configuration.certificateVerification = .none
            case .request:
                configuration.certificateVerification = .optionalVerification
            case .require:
                configuration.certificateVerification = .noHostnameVerification
            }

            if clientAuthentication != .none {
                guard let trustRootsPath else {
                    throw TLSConfigurationError.clientAuthenticationWithoutTrustRoots(
                        mode: clientAuthentication.rawValue)
                }
                do {
                    configuration.trustRoots = .certificates(
                        try NIOSSLCertificate.fromPEMFile(trustRootsPath))
                } catch {
                    throw TLSConfigurationError.unreadableTrustRoots(
                        path: trustRootsPath, underlying: error)
                }
            }
            return configuration
        }
    }

    public init(
        host: String = "127.0.0.1",
        port: Int = 8080,
        backlog: Int = 256,
        maxRequestBodyBytes: Int = 1 << 20,
        maxWebSocketFrameBytes: Int = 1 << 20,
        tls: TLS? = nil,
        onBound: (@Sendable (_ port: Int) -> Void)? = nil
    ) {
        self.host = host
        self.port = port
        self.backlog = backlog
        self.maxRequestBodyBytes = maxRequestBodyBytes
        self.maxWebSocketFrameBytes = maxWebSocketFrameBytes
        self.tls = tls
        self.onBound = onBound
    }

    public init(configuration: FlightCore.Configuration) throws {
        self.init(
            host: try configuration.getIfPresent("server.host", as: String.self) ?? "127.0.0.1",
            port: try configuration.getIfPresent("server.port", as: Int.self) ?? 8080,
            backlog: try configuration.getIfPresent("server.backlog", as: Int.self) ?? 256,
            maxRequestBodyBytes: try configuration.getIfPresent(
                "server.max-request-body-bytes", as: Int.self) ?? 1 << 20,
            maxWebSocketFrameBytes: try configuration.getIfPresent(
                "server.max-websocket-frame-bytes", as: Int.self) ?? 1 << 20,
            tls: try Self.readTLS(from: configuration)
        )
    }

    /// TLS is configured when a certificate and key are both named. Naming
    /// exactly one is a configuration error, not a fall back to plaintext.
    private static func readTLS(from configuration: FlightCore.Configuration) throws -> TLS? {
        let certificate = try configuration.getIfPresent(
            "server.tls.certificate-chain-path", as: String.self)
        let key = try configuration.getIfPresent("server.tls.private-key-path", as: String.self)

        switch (certificate, key) {
        case (nil, nil):
            return nil
        case (.some, nil):
            throw TLSConfigurationError.incompleteKeyPair(missing: "server.tls.private-key-path")
        case (nil, .some):
            throw TLSConfigurationError.incompleteKeyPair(
                missing: "server.tls.certificate-chain-path")
        case (.some(let certificate), .some(let key)):
            let raw =
                try configuration.getIfPresent("server.tls.client-authentication", as: String.self)
                ?? "none"
            guard let mode = TLS.ClientAuthentication(rawValue: raw) else {
                throw TLSConfigurationError.unknownClientAuthentication(
                    value: raw,
                    supported: TLS.ClientAuthentication.allCases.map(\.rawValue))
            }
            return TLS(
                certificateChainPath: certificate,
                privateKeyPath: key,
                trustRootsPath: try configuration.getIfPresent(
                    "server.tls.trust-roots-path", as: String.self),
                clientAuthentication: mode)
        }
    }
}

/// Why a TLS configuration could not be used. Every case names the key or
/// path at fault, because these surface at startup where the reader has the
/// config file open in front of them.
public enum TLSConfigurationError: Error, CustomStringConvertible {
    case incompleteKeyPair(missing: String)
    case unknownClientAuthentication(value: String, supported: [String])
    case unreadableCertificateChain(path: String, underlying: any Error)
    case unreadablePrivateKey(path: String, underlying: any Error)
    case unreadableTrustRoots(path: String, underlying: any Error)
    case clientAuthenticationWithoutTrustRoots(mode: String)

    public var description: String {
        switch self {
        case .incompleteKeyPair(let missing):
            return """
                TLS is half-configured: \(missing) is missing. Set both                 server.tls.certificate-chain-path and server.tls.private-key-path to serve                 HTTPS, or neither to serve plaintext behind a proxy.
                """
        case .unknownClientAuthentication(let value, let supported):
            return """
                server.tls.client-authentication is "\(value)"; expected one of                 \(supported.joined(separator: ", ")).
                """
        case .unreadableCertificateChain(let path, let underlying):
            return "could not read the TLS certificate chain at \(path): \(underlying)"
        case .unreadablePrivateKey(let path, let underlying):
            return "could not read the TLS private key at \(path): \(underlying)"
        case .unreadableTrustRoots(let path, let underlying):
            return "could not read the TLS trust roots at \(path): \(underlying)"
        case .clientAuthenticationWithoutTrustRoots(let mode):
            return """
                server.tls.client-authentication is "\(mode)", which verifies client                 certificates, but server.tls.trust-roots-path names no roots to verify them                 against.
                """
        }
    }
}
