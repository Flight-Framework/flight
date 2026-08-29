import FlightCore

/// Channels' runtime settings, read once at bootstrap from the app
/// `Configuration` (the same source `FlightTransport` reads its port from).
public struct ChannelsConfiguration: Sendable, Equatable {
    /// A socket silent for longer than this is closed. "Silent" means
    /// no frames at all — any inbound frame, heartbeat or otherwise, counts
    /// as liveness. Clients heartbeat well inside this window (the
    /// reference clients default to 25s against this 60s).
    public var heartbeatTimeout: Duration

    /// How often the liveness watchdog checks. Defaults to a quarter of the
    /// timeout: a socket is detected dead at most timeout + interval after
    /// its last frame, and the check itself is two atomic reads.
    public var heartbeatCheckInterval: Duration

    /// How many outbound envelopes one socket may have queued before the
    /// oldest are dropped.
    ///
    /// The queue used to be unbounded. A client that stopped reading — a
    /// backgrounded tab, a wedged connection, a phone that walked into a
    /// tunnel — accumulated every message published to its topics with no
    /// ceiling, so one stalled subscriber could exhaust the server's memory
    /// while the watchdog waited out its heartbeat timeout.
    ///
    /// Dropping the *oldest* is deliberate: a client that falls behind on a
    /// realtime feed wants the recent state, not a backlog it can never catch
    /// up on. Drops are counted and logged.
    public var outboundBufferSize: Int

    /// How long one outbound frame may take to reach the peer before the
    /// socket is closed. `nil` waits forever, which is what this used to do.
    ///
    /// The bound the heartbeat watchdog cannot supply. A client that keeps
    /// *sending* heartbeats while never *reading* is live by the watchdog's
    /// definition — inbound frames are what it counts — so the watchdog never
    /// fires, and the writer sits in `connection.send` against a TCP window
    /// that never opens, indefinitely. Memory stays bounded by
    /// ``outboundBufferSize``; what leaks is a task and a connection each
    /// time, which is the shape of a slow resource exhaustion rather than a
    /// fast one.
    ///
    /// Per frame, not per socket: a healthy socket that has been open for
    /// days is not close to this bound, and a socket that cannot absorb one
    /// frame in this long is not going to absorb the next.
    public var writeTimeout: Duration?

    public init(
        heartbeatTimeout: Duration = .seconds(60),
        heartbeatCheckInterval: Duration? = nil,
        outboundBufferSize: Int = 256,
        writeTimeout: Duration? = .seconds(30)
    ) {
        self.heartbeatTimeout = heartbeatTimeout
        self.heartbeatCheckInterval = heartbeatCheckInterval ?? (heartbeatTimeout / 4)
        self.outboundBufferSize = max(1, outboundBufferSize)
        self.writeTimeout = writeTimeout
    }

    /// Keys, under Flight's usual dotted namespace:
    /// - `flight.channels.heartbeat-timeout-seconds` (Double, default 60)
    /// - `flight.channels.heartbeat-check-interval-seconds` (Double,
    ///   default: a quarter of the timeout)
    /// - `flight.channels.outbound-buffer-size` (Int, default 256)
    /// - `flight.channels.write-timeout-seconds` (Double, default 30; 0
    ///   disables)
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
            heartbeatCheckInterval: checkSeconds.map { .seconds($0) },
            outboundBufferSize: try configuration.getIfPresent(
                "flight.channels.outbound-buffer-size", as: Int.self) ?? 256,
            // 0 disables it explicitly — an operator who wants no bound
            // should write that down rather than delete a line.
            writeTimeout: try configuration.getIfPresent(
                "flight.channels.write-timeout-seconds", as: Double.self)
                .map { $0 <= 0 ? nil : Duration.seconds($0) } ?? .seconds(30)
        )
    }
}
