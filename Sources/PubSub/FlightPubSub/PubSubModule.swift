import FlightCore

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
/// as its `service`. See README.md "Writing an adapter module".
public struct FlightPubSubModule: FlightModule {
    public init() {}

    public func configure(_ container: Container) throws {
        container.register(LocalPubSub.self, scope: .singleton) { _ in
            LocalPubSub()
        }
        container.register((any PubSub).self, scope: .singleton) { container in
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
                        AdapterCandidate(
                            configurationKey: "pubsub.valkey.url",
                            module: "FlightPubSubValkeyModule")
                    ])
                adapter = nil
            }
            guard let adapter else { return local }
            return ClusteredPubSub(local: local, adapter: adapter)
        }
    }
}
