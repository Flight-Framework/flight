import FlightChannels
import FlightCore
import FlightPubSub
import ServiceLifecycle
import struct Foundation.UUID

/// Registers Presence with the container. Depends on the
/// PubSub and Channels modules; provides:
///
/// - `settings` (`PresenceConfiguration`) — node name and liveness intervals,
///   read from configuration once in `init`.
/// - `tracker` / `presence` (`(any Presence)`) — the engine, built in `init`.
///   The deployment mode is decided by *argument*, not by probing: a
///   `membershipMonitor` means membership mode; an `adapter` without one means
///   the degraded heartbeat mode; neither means single-node.
/// - `service` (`PresenceService`) — the periodic work, in the app
///   `ServiceGroup`. Logs the active failure-detection mode at startup.
///
/// A channels module takes `(any Presence)` and closes its room channels over
/// it — the composition root wires the value in:
///
///     struct AppChannels: FlightModule {
///         let channels: [ChannelRegistration]
///         init(presence: any Presence) {
///             self.channels = [
///                 ChannelRegistration("room:*") { _ in RoomChannel(presence: presence) }
///             ]
///         }
///     }
///
/// A struct holding what it provides: the tracker exists as a value before
/// anything runs, and the service is built from it — nothing is resolved at
/// `run()`.
public struct FlightPresenceModule: FlightModule {
    public static var dependencies: [any FlightModule.Type] {
        [FlightPubSubModule.self, FlightChannelsModule.self]
    }

    /// Node name, heartbeat and expiry windows, read once at composition.
    public let settings: PresenceConfiguration

    /// The tracker, concretely.
    public let tracker: PresenceTracker

    /// What consumers use. The same instance as `tracker`.
    public let presence: any Presence

    /// Kept for the service, which watches it when the deployment has one.
    private let monitor: (any PresenceMembershipMonitor)?

    /// The gossip bus, kept for the service.
    private let gossipBus: any PubSub

    /// - Parameters:
    ///   - configuration: For `flight.presence.*`.
    ///   - localBus: `FlightPubSubModule.local` — intra-node fan-out.
    ///   - gossipBus: `FlightPubSubModule.bus` — what carries presence
    ///     between nodes when the deployment is clustered.
    ///   - adapter: Present exactly when the deployment is clustered. Its
    ///     presence is what moves this node off `.singleNode`.
    ///   - membershipMonitor: A cluster that can say who is up. With one,
    ///     presence runs in `.membership` mode; without, it falls back to
    ///     heartbeat expiry.
    ///
    /// The last two used to be container probes — `resolve`, catching
    /// `.notRegistered` to mean "not in this deployment". That is a runtime
    /// scan answering a question about how the application was assembled,
    /// which the composition root knows; `FlightPubSubModule` had the same
    /// probe for the same reason and lost it the same way.
    public init(
        configuration: Configuration,
        localBus: LocalPubSub,
        gossipBus: any PubSub,
        adapter: (any DistributedPubSubAdapter)? = nil,
        membershipMonitor: (any PresenceMembershipMonitor)? = nil
    ) throws {
        let settings = try PresenceConfiguration(configuration: configuration)
        let mode: PresenceMode =
            adapter == nil ? .singleNode : (membershipMonitor == nil ? .heartbeatExpiry : .membership)
        let tracker = PresenceTracker(
            replica: PresenceReplicaID(name: settings.nodeName, boot: Self.generateBoot()),
            mode: mode,
            configuration: settings,
            localBus: localBus,
            gossipBus: gossipBus
        )
        self.settings = settings
        self.tracker = tracker
        self.presence = tracker
        self.monitor = membershipMonitor
        self.gossipBus = gossipBus
    }

    public init() {
        preconditionFailure(
            "FlightPresenceModule takes its buses and configuration in "
                + "init(configuration:localBus:gossipBus:adapter:membershipMonitor:), so it cannot "
                + "be instantiated from its type. Pass `composedBy: flightComposeModules` to "
                + "Flight.run — `flight new` writes that argument — or construct the module "
                + "yourself and use the entry point taking module instances.")
    }

    /// Projects what this module already holds.
    /// Built from what this module holds. It used to be built from the
    /// stashed `Container` and resolve at `run()`, because the service is
    /// constructed pre-freeze and the components did not exist yet — they do
    /// now, before any container does.
    public var service: (any Service)? {
        PresenceService(
            tracker: tracker,
            pubsub: gossipBus,
            monitor: monitor,
            configuration: settings)
    }

    /// 12 hex chars of boot uniqueness (48 bits): enough that no two
    /// processes in one cluster's lifetime collide, short enough to ride
    /// in every meta ref.
    static func generateBoot() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)).lowercased()
    }
}
