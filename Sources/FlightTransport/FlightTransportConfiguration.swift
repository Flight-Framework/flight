import FlightCore
import FlightWeb

/// `FlightTransport`'s settings, read from the app-wide Flight configuration
/// (flight.yaml / FLIGHT_* environment variables) under `server.*`:
///
///     server.host: 127.0.0.1
///     server.port: 8080
///     server.backlog: 256
///     server.max-request-body-bytes: 1048576
///     server.max-websocket-frame-bytes: 1048576
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
    /// Invoked once the listening socket is bound, with the actual port —
    /// the seam that makes `port: 0` (ephemeral) usable in tests.
    public var onBound: (@Sendable (_ port: Int) -> Void)?

    public init(
        host: String = "127.0.0.1",
        port: Int = 8080,
        backlog: Int = 256,
        maxRequestBodyBytes: Int = 1 << 20,
        maxWebSocketFrameBytes: Int = 1 << 20,
        onBound: (@Sendable (_ port: Int) -> Void)? = nil
    ) {
        self.host = host
        self.port = port
        self.backlog = backlog
        self.maxRequestBodyBytes = maxRequestBodyBytes
        self.maxWebSocketFrameBytes = maxWebSocketFrameBytes
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
                "server.max-websocket-frame-bytes", as: Int.self) ?? 1 << 20
        )
    }
}
