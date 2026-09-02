import FlightCore

/// Per-subscriber buffering, as a deployment writes it in `flight.yaml`.
///
/// A separate type from `LocalPubSub.BufferingPolicy` (which is
/// `AsyncStream.Continuation.BufferingPolicy`, a stdlib type) because
/// conforming that retroactively would attach Flight's configuration format
/// to every `AsyncStream` in every program that links this package.
///
/// Written as `unbounded`, or a bound and a count: `newest:1024`,
/// `oldest:1024`.
public enum PubSubBufferingPolicy: Sendable, Equatable, ConfigDecodable {
    /// BEAM-mailbox behavior: nothing is dropped, memory is the only limit.
    case unbounded
    /// A memory ceiling; when full, the oldest pending message is dropped.
    case bufferingOldest(Int)
    /// A memory ceiling; when full, the newest message is dropped.
    case bufferingNewest(Int)

    public init?(configValue: String) {
        let trimmed = configValue.trimmingCharacters(in: .whitespaces).lowercased()
        if trimmed == "unbounded" {
            self = .unbounded
            return
        }
        let parts = trimmed.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, let count = Int(parts[1].trimmingCharacters(in: .whitespaces)),
            count > 0
        else { return nil }
        switch parts[0].trimmingCharacters(in: .whitespaces) {
        case "oldest": self = .bufferingOldest(count)
        case "newest": self = .bufferingNewest(count)
        default: return nil
        }
    }

    var streamPolicy: LocalPubSub.BufferingPolicy {
        switch self {
        case .unbounded: .unbounded
        case .bufferingOldest(let count): .bufferingOldest(count)
        case .bufferingNewest(let count): .bufferingNewest(count)
        }
    }
}

/// How long a clustered `publish` waits on the adapter for the remote hop.
///
/// A distinct type rather than `Duration?` because absent and "wait forever"
/// are different answers and a bare optional cannot hold both: nil would have
/// to mean "not configured, use the default" *and* "configured to wait
/// indefinitely".
public enum PubSubBroadcastTimeout: Sendable, Equatable, ConfigDecodable {
    case after(Duration)
    /// Wait for the adapter however long it takes. Local delivery has already
    /// happened; this only governs the remote hop.
    case never

    public init?(configValue: String) {
        if configValue.trimmingCharacters(in: .whitespaces).lowercased() == "never" {
            self = .never
            return
        }
        guard let duration = Duration(configValue: configValue) else { return nil }
        self = .after(duration)
    }

    var duration: Duration? {
        switch self {
        case .after(let duration): duration
        case .never: nil
        }
    }
}

/// The PubSub module's settings, read from `flight.yaml` at `freeze()`.
///
/// These used to be `init` parameters on `FlightPubSubModule`. They were
/// unreachable: `Flight.bootstrap` and `Flight.assemble` both take
/// `[any FlightModule.Type]` and instantiate with `init()`, so no deployment
/// could set any of them — the documented example passed a module *instance*
/// and did not compile. They are deployment knobs, so they live where
/// deployment knobs live.
struct PubSubSettings: Sendable {
    var bufferingPolicy: PubSubBufferingPolicy
    var nodeID: String?
    var broadcastTimeout: PubSubBroadcastTimeout

    static let bufferingKey = "pubsub.buffering"
    static let nodeIDKey = "pubsub.node_id"
    static let broadcastTimeoutKey = "pubsub.broadcast_timeout"

    /// Malformed values throw rather than falling back: a node told to bound
    /// its buffers at 1024 and silently running unbounded is the bug the
    /// setting exists to prevent.
    init(configuration: Configuration) throws {
        bufferingPolicy =
            try configuration.getIfPresent(Self.bufferingKey, as: PubSubBufferingPolicy.self)
            ?? .unbounded
        nodeID = try configuration.getIfPresent(Self.nodeIDKey, as: String.self)
        broadcastTimeout =
            try configuration.getIfPresent(
                Self.broadcastTimeoutKey, as: PubSubBroadcastTimeout.self) ?? .after(.seconds(5))
    }
}
