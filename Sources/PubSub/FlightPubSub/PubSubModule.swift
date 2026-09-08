import FlightCore
import class Foundation.ProcessInfo
import ServiceLifecycle

/// Owns PubSub: the local core, the bus consumers use, and — when the
/// deployment is clustered — the relay that feeds it.
///
/// - `local` is the concrete core, for anything that specifically wants
///   intra-node-only fan-out.
/// - `bus` is what consumers (Channels, Presence, app code) use: the local
///   core on a single node, a `ClusteredPubSub` wrapping it when an adapter
///   was supplied. Consumers never know which.
///
/// **Composed by argument, not by presence.** This used to decide at
/// `freeze()` by asking the container whether anyone had registered a
/// `DistributedPubSubAdapter`, catching `.notRegistered` to mean "single
/// node" — a runtime scan answering a question about how the application was
/// assembled. An adapter module therefore had to depend on this one, and had
/// to remember to expose `PubSubRelayService` itself; forgetting gave a
/// cluster that silently never relayed.
///
/// Now an adapter module provides an adapter, and that is all it does. This
/// module takes it, builds the bus around it, and owns the relay — so the
/// direction is reversed: an adapter module is a *dependency* of this one.
/// See `Docs/pubsub.md`, "Writing an adapter module".
public struct FlightPubSubModule: FlightModule {

    /// The concrete local core.
    public let local: LocalPubSub

    /// What consumers use.
    public let bus: any PubSub

    /// Non-nil exactly when an adapter was supplied — which is what decides
    /// whether there is a relay to run.
    private let clustered: ClusteredPubSub?

    /// Buffering, node identity and the broadcast timeout come from
    /// `flight.yaml` (`pubsub.buffering`, `pubsub.node_id`,
    /// `pubsub.broadcast_timeout`); `Docs/pubsub.md` documents the keys.
    ///
    /// These used to be `init` parameters that could not exist: both public
    /// entry points took `[any FlightModule.Type]` and instantiated with
    /// `init()`, so nothing a deployment wrote could reach them. Flight's own
    /// worked adapter example smuggles its cluster in through a `@TaskLocal`
    /// for the same reason.
    ///
    /// `adapter` nil means single node — the 90% case. A parameter rather
    /// than a container lookup because "is there an adapter in this
    /// deployment" is a fact about how the application was composed, which
    /// the composition root knows and a runtime scan could only discover.
    public init(
        configuration: Configuration,
        adapter: (any DistributedPubSubAdapter)? = nil
    ) throws {
        let settings = try PubSubSettings(configuration: configuration)
        let local = LocalPubSub(bufferingPolicy: settings.bufferingPolicy.streamPolicy)
        self.local = local

        guard let adapter else {
            // Configuration naming an adapter nobody loaded would otherwise
            // give every node its own private fan-out, with no symptom until
            // production.
            try configuration.requireNoUnloadedAdapter(
                feature: "PubSub",
                candidates: [
                    AdapterCandidate(
                        configurationKey: "pubsub.valkey.url",
                        module: "FlightPubSubValkeyModule (flight-data)"),
                    AdapterCandidate(
                        configurationKey: "pubsub.adapter.url",
                        module: "a DistributedPubSubAdapter module"),
                ])
            self.clustered = nil
            self.bus = local
            return
        }
        let clustered = ClusteredPubSub(
            local: local, adapter: adapter,
            nodeID: settings.nodeID ?? ProcessInfo.processInfo.hostName,
            broadcastTimeout: settings.broadcastTimeout.duration)
        self.clustered = clustered
        self.bus = clustered
    }

    /// This module takes its configuration, so it cannot be built from its
    /// type alone — `isTypeConstructible` says so, and every supported path
    /// checks that flag and throws before reaching this initializer.
    public static var isTypeConstructible: Bool { false }

    /// The backstop behind that flag, for a caller that writes
    /// `FlightPubSubModule()` directly. `FlightModule` still requires `init()`
    /// while the type-based entry points exist; the message says what to do
    /// rather than trapping anonymously.
    public init() {
        preconditionFailure(
            "FlightPubSubModule takes its configuration in init(configuration:adapter:), so it "
                + "cannot be instantiated from its type. Pass `composedBy: flightComposeModules` "
                + "to Flight.run — `flight new` writes that argument — or construct the module "
                + "yourself and use the entry point taking module instances.")
    }

    /// Projects what this module already holds. Nothing is constructed here:
    /// the components exist before `configure` runs, which is the difference
    /// between a module that registers and one that owns.
    public func configure(_ container: Container) throws {
        let local = self.local
        let bus = self.bus
        container.register(LocalPubSub.self, scope: .singleton) { _ in local }
        container.register((any PubSub).self, scope: .singleton) { _ in bus }
    }

    /// The relay, when clustered. It belongs here rather than to the adapter
    /// module because this is what has both halves — the adapter to drain and
    /// the local core to drain it into. An adapter module used to have to
    /// remember to expose it, and a cluster whose author forgot relayed
    /// nothing, silently.
    public var service: (any Service)? {
        clustered.map { PubSubRelayService(clustered: $0) }
    }
}
