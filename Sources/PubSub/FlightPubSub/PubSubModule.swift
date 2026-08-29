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

    /// How each subscriber's pending messages buffer.
    ///
    /// The module used to hardcode `LocalPubSub()`, so the bounded policies
    /// `Docs/pubsub.md` advertises were unreachable to anyone who bootstrapped
    /// through it: the container's first registration wins, a second one
    /// fails `freeze()`, and `override` is documented as existing for tests.
    /// The knob had to be here or it did not exist.
    public var bufferingPolicy: LocalPubSub.BufferingPolicy

    /// A human-meaningful name for this node, surfaced in cluster
    /// diagnostics. Defaulting it to a random UUID — which is what happened —
    /// defeats the point of it being human-meaningful.
    public var nodeID: String?

    /// How long a clustered `publish` waits on the adapter before giving up
    /// on the remote hop. Local delivery has already happened by then.
    public var broadcastTimeout: Duration?

    /// The bootstrap path — `modules: [FlightPubSubModule.self]` instantiates
    /// through this. Configure by passing an instance instead.
    public init() {
        self.init(bufferingPolicy: .unbounded)
    }

    public init(
        bufferingPolicy: LocalPubSub.BufferingPolicy = .unbounded,
        nodeID: String? = nil,
        broadcastTimeout: Duration? = .seconds(5)
    ) {
        self.bufferingPolicy = bufferingPolicy
        self.nodeID = nodeID
        self.broadcastTimeout = broadcastTimeout
    }

    public func configure(_ container: Container) throws {
        container.register(LocalPubSub.self, scope: .singleton) { [bufferingPolicy] _ in
            LocalPubSub(bufferingPolicy: bufferingPolicy)
        }
        container.register((any PubSub).self, scope: .singleton) { [nodeID, broadcastTimeout] container in
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
                nodeID: nodeID ?? ProcessInfo.processInfo.hostName,
                broadcastTimeout: broadcastTimeout)
        }
    }
}
