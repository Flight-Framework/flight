import struct Foundation.Data
import class Foundation.JSONDecoder
import class Foundation.JSONEncoder

/// Inter-node presence traffic (design §4): rides Flight PubSub on one
/// reserved internal topic, reusing the fan-out and distributed-adapter
/// machinery already built — Presence adds no transport of its own.
///
/// One topic, not the design doc's literal `flight:presence:<topic>`
/// family: PubSub is exact-match with no wildcards (PubSub §3), so a node
/// cannot subscribe to "every presence gossip topic" — and every node
/// needs all of it, because presence state is replicated everywhere (§8).
/// Per-channel-topic payloads travel *inside* the messages instead.
/// Recorded as a design delta in README.md.
public enum PresenceGossip {
    /// The reserved gossip topic. Applications must not register channels
    /// matching it (clients could then join it; its frames are not
    /// broadcast frames and would be dropped by the socket pump with log
    /// noise).
    public static let topic = "flight:presence"

    /// Wire version. A frame with an unknown version is dropped with a
    /// warning — mixed-version clusters degrade to anti-entropy silence,
    /// never to misinterpretation.
    public static let version = 1
}

/// What replicas say to each other. Every state-bearing case carries a
/// delta-state (`PresenceCRDTState`); receiving one is always the same
/// operation — join it.
public enum PresenceGossipMessage: Sendable, Equatable, Codable {
    /// An incremental change: a track, untrack, or update, as a delta.
    case delta(from: PresenceReplicaID, state: PresenceCRDTState)
    /// The sender's full own-entry state — the periodic re-announce
    /// (heartbeat in degraded mode, anti-entropy in membership mode) and
    /// the response to `syncRequest`.
    case snapshot(from: PresenceReplicaID, state: PresenceCRDTState)
    /// "I just started; tell me what you know." Peers answer with their
    /// snapshot, giving a fresh node the cluster's presence state without
    /// waiting a full re-announce interval.
    case syncRequest(from: PresenceReplicaID)

    public var sender: PresenceReplicaID {
        switch self {
        case .delta(let from, _), .snapshot(let from, _), .syncRequest(let from):
            return from
        }
    }
}

/// The on-wire frame: version + message, JSON-encoded into the PubSub
/// message payload (opaque to PubSub, PubSub §4).
struct PresenceGossipFrame: Codable {
    let v: Int
    let message: PresenceGossipMessage

    static func encode(_ message: PresenceGossipMessage) -> Data? {
        try? JSONEncoder().encode(PresenceGossipFrame(v: PresenceGossip.version, message: message))
    }

    /// nil for undecodable payloads; `.some(nil)`… avoided — returns the
    /// message, or nil with `unknownVersion` distinguishing the two drop
    /// reasons for logging.
    static func decode(_ data: Data) -> (message: PresenceGossipMessage?, unknownVersion: Int?) {
        struct VersionProbe: Codable { let v: Int }
        guard let frame = try? JSONDecoder().decode(PresenceGossipFrame.self, from: data) else {
            let probed = try? JSONDecoder().decode(VersionProbe.self, from: data)
            if let probed, probed.v != PresenceGossip.version {
                return (nil, probed.v)
            }
            return (nil, nil)
        }
        guard frame.v == PresenceGossip.version else { return (nil, frame.v) }
        return (frame.message, nil)
    }
}
