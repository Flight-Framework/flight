import FlightCore
import struct Foundation.UUID

/// Presence's runtime settings, read once at bootstrap from the app
/// `Configuration` — the same source and dotted-key convention as
/// `ChannelsConfiguration`.
public struct PresenceConfiguration: Sendable, Equatable {
    /// This node's stable name — the `name` half of the replica id its
    /// gossip carries, and the vocabulary a membership monitor speaks
    /// (`PresenceMembershipEvent.down(node:)` matches against it). Set it
    /// explicitly in any multi-node deployment with a membership monitor;
    /// the generated default is fine everywhere else.
    public var nodeName: String

    /// How often this node re-announces its full own-presence state. In
    /// degraded mode (§5.2) this is the heartbeat that keeps its entries
    /// alive on peers; in membership mode it is anti-entropy repairing any
    /// gossip delta the at-most-once transport dropped.
    public var heartbeatInterval: Duration

    /// Degraded mode only: a replica not heard from for this long is
    /// marked down and its entries leave the visible list. Must be
    /// comfortably larger than `heartbeatInterval` — a single missed
    /// heartbeat must not flap a node (§5.2).
    public var downAfter: Duration

    /// Both modes: a replica continuously down for this long is purged —
    /// entries deleted, context forgotten. Until then its state is kept
    /// hidden, so a wrongly-evicted node that resumes gossiping (§5.2's
    /// flap) comes back as joins without data loss.
    public var permdownAfter: Duration

    /// How often the liveness sweep runs. Defaults to a quarter of
    /// `downAfter`, floored at 100ms.
    public var sweepInterval: Duration

    public init(
        nodeName: String? = nil,
        heartbeatInterval: Duration = .seconds(5),
        downAfter: Duration = .seconds(15),
        permdownAfter: Duration = .seconds(300),
        sweepInterval: Duration? = nil
    ) {
        self.nodeName = nodeName ?? "node-\(UUID().uuidString.prefix(8).lowercased())"
        self.heartbeatInterval = heartbeatInterval
        self.downAfter = downAfter
        self.permdownAfter = permdownAfter
        self.sweepInterval = sweepInterval ?? max(.milliseconds(100), downAfter / 4)
    }

    /// Keys, under Flight's usual dotted namespace:
    /// - `flight.presence.node-name` (String, default: generated)
    /// - `flight.presence.heartbeat-interval-seconds` (Double, default 5)
    /// - `flight.presence.down-after-seconds` (Double, default 15)
    /// - `flight.presence.permdown-after-seconds` (Double, default 300)
    /// - `flight.presence.sweep-interval-seconds` (Double, default:
    ///   `down-after / 4`, floored at 0.1)
    public init(configuration: Configuration) throws {
        let nodeName = try configuration.getIfPresent("flight.presence.node-name", as: String.self)
        let heartbeat = configuration.get("flight.presence.heartbeat-interval-seconds", default: 5.0)
        let downAfter = configuration.get("flight.presence.down-after-seconds", default: 15.0)
        let permdown = configuration.get("flight.presence.permdown-after-seconds", default: 300.0)
        let sweep = try configuration.getIfPresent("flight.presence.sweep-interval-seconds", as: Double.self)

        guard heartbeat > 0, downAfter > 0, permdown > 0 else {
            throw PresenceConfigurationError.nonPositiveInterval
        }
        guard downAfter > heartbeat else {
            throw PresenceConfigurationError.downAfterNotAboveHeartbeat(
                heartbeat: heartbeat, downAfter: downAfter
            )
        }
        self.init(
            nodeName: nodeName,
            heartbeatInterval: .seconds(heartbeat),
            downAfter: .seconds(downAfter),
            permdownAfter: .seconds(permdown),
            sweepInterval: sweep.map { .seconds($0) }
        )
    }
}

public enum PresenceConfigurationError: Error, CustomStringConvertible, Sendable, Equatable {
    case nonPositiveInterval
    case downAfterNotAboveHeartbeat(heartbeat: Double, downAfter: Double)

    public var description: String {
        switch self {
        case .nonPositiveInterval:
            return "flight.presence intervals must be positive."
        case .downAfterNotAboveHeartbeat(let heartbeat, let downAfter):
            return """
            flight.presence.down-after-seconds (\(downAfter)) must exceed \
            flight.presence.heartbeat-interval-seconds (\(heartbeat)); otherwise every \
            heartbeat gap flaps the node (design §5.2).
            """
        }
    }
}
