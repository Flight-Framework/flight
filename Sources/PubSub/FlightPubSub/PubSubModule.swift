import FlightCore
import class Foundation.ProcessInfo

/// Registers PubSub with the container.
///
/// Two components:
/// - `LocalPubSub` — the concrete local core, resolvable directly by
///   anything that specifically wants intra-node-only fan-out.
/// - `any PubSub` — what consumers (Channels, Presence, Live, app code)
///   resolve. Its factory runs at `freeze()`, after every module has
///   configured, and composes by *presence*: if some module registered a
///   `DistributedPubSubAdapter` component, the app's PubSub is a `ClusteredPubSub`
///   wrapping the local core; otherwise it IS the local core. Consumers never
///   know which.
///
/// No `service`: the local core is demand-driven. A distributed
/// deployment's long-running half — the relay — belongs to the module that
/// provides the adapter, which registers its adapter component, declares
/// `FlightPubSubModule` as a dependency, and exposes
/// `PubSubRelayService(container:)` (plus any connection service of its own)
/// as its `service`. See `Docs/pubsub.md`, "Writing an adapter module".
public struct FlightPubSubModule: FlightModule {

    /// Buffering, node identity and the broadcast timeout are read from
    /// `flight.yaml` (`pubsub.buffering`, `pubsub.node_id`,
    /// `pubsub.broadcast_timeout`); `PubSubSettings` is the internal type
    /// that reads them, and `Docs/pubsub.md` documents the keys.
    ///
    /// They used to be `init` parameters here, which meant they did not
    /// exist: both public entry points take `[any FlightModule.Type]` and
    /// instantiate with `init()`, so nothing a deployment wrote could reach
    /// them.
    public init() {}

    public func configure(_ container: Container) throws {
        // Registered here, built at freeze() — reading configuration during
        // the registration phase trips Core's "resolution begins at freeze()"
        // precondition, the same reason FlightWebModule defers its coders.
        container.register(LocalPubSub.self, scope: .singleton) { container in
            let settings = try PubSubSettings(configuration: container.resolve(Configuration.self))
            return LocalPubSub(bufferingPolicy: settings.bufferingPolicy.streamPolicy)
        }
        container.register((any PubSub).self, scope: .singleton) { container in
            let settings = try PubSubSettings(configuration: container.resolve(Configuration.self))
            let local = try container.resolve(LocalPubSub.self)
            let adapter: (any DistributedPubSubAdapter)?
            do {
                adapter = try container.resolve((any DistributedPubSubAdapter).self)
            } catch let error as ResolutionError {
                // Absent adapter = single-node deployment, the 90% case.
                // Any other resolution failure is a real wiring bug.
                guard case .notRegistered = error else { throw error }
                // ...unless configuration named an adapter nobody loaded, in
                // which case falling back silently would give every node its
                // own private fan-out and no symptom until production.
                try container.resolve(Configuration.self).requireNoUnloadedAdapter(
                    feature: "PubSub",
                    candidates: [
                        // `FlightPubSubValkeyModule` does not exist yet, so
                        // an error naming it told the operator to add a
                        // module they cannot obtain. The check is still worth
                        // making — these keys are unambiguous intent — but it
                        // has to name something reachable.
                        AdapterCandidate(
                            configurationKey: "pubsub.valkey.url",
                            module: "a DistributedPubSubAdapter module (none ships yet — see Docs/pubsub.md)"
                        ),
                        AdapterCandidate(
                            configurationKey: "pubsub.adapter.url",
                            module: "a DistributedPubSubAdapter module (none ships yet — see Docs/pubsub.md)"
                        ),
                    ])
                adapter = nil
            }
            guard let adapter else { return local }
            return ClusteredPubSub(
                local: local, adapter: adapter,
                nodeID: settings.nodeID ?? ProcessInfo.processInfo.hostName,
                broadcastTimeout: settings.broadcastTimeout.duration)
        }
    }
}
