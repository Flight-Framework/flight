import FlightCore

/// Channels' runtime settings, read once at bootstrap from the app
/// `Configuration` (the same source `FlightTransport` reads its port from).
public struct ChannelsConfiguration: Sendable, Equatable {
    /// A socket silent for longer than this is closed (§6). "Silent" means
    /// no frames at all — any inbound frame, heartbeat or otherwise, counts
    /// as liveness. Clients heartbeat well inside this window (the
    /// reference clients default to 25s against this 60s).
    public var heartbeatTimeout: Duration

    /// How often the liveness watchdog checks. Defaults to a quarter of the
    /// timeout: a socket is detected dead at most timeout + interval after
    /// its last frame, and the check itself is two atomic reads.
    public var heartbeatCheckInterval: Duration

    public init(
        heartbeatTimeout: Duration = .seconds(60),
        heartbeatCheckInterval: Duration? = nil
    ) {
        self.heartbeatTimeout = heartbeatTimeout
        self.heartbeatCheckInterval = heartbeatCheckInterval ?? (heartbeatTimeout / 4)
    }

    /// Keys, under Flight's usual dotted namespace:
    /// - `flight.channels.heartbeat-timeout-seconds` (Double, default 60)
    /// - `flight.channels.heartbeat-check-interval-seconds` (Double,
    ///   default: a quarter of the timeout)
    public init(configuration: Configuration) throws {
        let timeoutSeconds = configuration.get(
            "flight.channels.heartbeat-timeout-seconds",
            default: 60.0
        )
        let timeout = Duration.seconds(timeoutSeconds)
        let checkSeconds = try configuration.getIfPresent(
            "flight.channels.heartbeat-check-interval-seconds",
            as: Double.self
        )
        self.init(
            heartbeatTimeout: timeout,
            heartbeatCheckInterval: checkSeconds.map { .seconds($0) }
        )
    }
}
