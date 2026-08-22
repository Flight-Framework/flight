import FlightChannels
import FlightCore
import FlightPubSub
import ServiceLifecycle
import struct Foundation.UUID

/// Registers Presence with the container (design §9). Depends on the
/// PubSub and Channels modules; registers:
///
/// - `PresenceConfiguration` — node name and liveness intervals, read from
///   the app configuration once.
/// - `PresenceTracker` / `(any Presence)` — the engine. Its factory runs
///   at `freeze()`, after every module has configured, and detects the
///   deployment mode by *presence* (the same composition-by-presence as
///   `FlightPubSubModule`): a registered `PresenceMembershipMonitor` means
///   membership mode; a `DistributedPubSubAdapter` without one means the
///   degraded heartbeat mode; neither means single-node.
/// - `PresenceService` — the periodic work (§9), in the app
///   `ServiceGroup`. Logs the active failure-detection mode at startup.
///
/// An app module declares the dependency and resolves `(any Presence)`
/// into its channels:
///
///     struct AppModule: FlightModule {
///         static var dependencies: [any FlightModule.Type] { [FlightPresenceModule.self] }
///         func configure(_ container: Container) throws {
///             container.registerChannel("room:*") { c in
///                 RoomChannel(presence: try c.resolve((any Presence).self))
///             }
///             container.registerChannelSocket("/socket")
///         }
///     }
///
/// A class, because it stashes the container during `configure` for the
/// service to resolve from later, post-freeze — the same shape as any
/// service-owning module (Core §4, Web's `FlightWebModule`).
public final class FlightPresenceModule: FlightModule {
    public static var dependencies: [any FlightModule.Type] {
        [FlightPubSubModule.self, FlightChannelsModule.self]
    }

    private var container: Container?

    public init() {}

    public func configure(_ container: Container) throws {
        self.container = container

        container.register(PresenceConfiguration.self, scope: .singleton) { container in
            try PresenceConfiguration(configuration: container.resolve(Configuration.self))
        }

        container.register(PresenceTracker.self, scope: .singleton) { container in
            let configuration = try container.resolve(PresenceConfiguration.self)
            let adapter: (any DistributedPubSubAdapter)? = try Self.optional(container) {
                try $0.resolve((any DistributedPubSubAdapter).self)
            }
            let monitor: (any PresenceMembershipMonitor)? = try Self.optional(container) {
                try $0.resolve((any PresenceMembershipMonitor).self)
            }
            let mode: PresenceMode =
                adapter == nil ? .singleNode : (monitor == nil ? .heartbeatExpiry : .membership)
            return PresenceTracker(
                replica: PresenceReplicaID(name: configuration.nodeName, boot: Self.generateBoot()),
                mode: mode,
                configuration: configuration,
                localBus: try container.resolve(LocalPubSub.self),
                gossipBus: try container.resolve((any PubSub).self)
            )
        }

        container.register((any Presence).self, scope: .singleton) { container in
            try container.resolve(PresenceTracker.self)
        }
    }

    public var service: (any Service)? {
        container.map { PresenceService(container: $0) }
    }

    /// Absent component = deployment choice, the normal case. Any other
    /// resolution failure is a real wiring bug and must surface — the same
    /// discipline as `FlightPubSubModule`'s adapter probe.
    private static func optional<T>(_ container: Container, _ resolve: (Container) throws -> T) throws -> T? {
        do {
            return try resolve(container)
        } catch let error as ResolutionError {
            guard case .notRegistered = error else { throw error }
            return nil
        }
    }

    /// 12 hex chars of boot uniqueness (48 bits): enough that no two
    /// processes in one cluster's lifetime collide, short enough to ride
    /// in every meta ref.
    static func generateBoot() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)).lowercased()
    }
}
