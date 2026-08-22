import FlightCore
import Logging
import ServiceLifecycle

/// Wiring errors surfaced at service start — misconfiguration, not runtime
/// conditions.
public enum PubSubWiringError: Error, CustomStringConvertible, Sendable {
    /// `PubSubRelayService` was wired into an app whose `PubSub` component is not
    /// a `ClusteredPubSub` — i.e. no `DistributedPubSubAdapter` was
    /// registered. A single-node app needs no relay service at all (§6).
    case pubSubIsNotClustered

    public var description: String {
        switch self {
        case .pubSubIsNotClustered:
            return "PubSubRelayService requires a ClusteredPubSub, but the container's PubSub component is local-only. Register a DistributedPubSubAdapter component (see FlightPubSubModule), or drop the relay service from the module wiring."
        }
    }
}

/// The long-running half of a distributed deployment (§6): drains the
/// adapter's incoming stream into local fan-out for the app's lifetime.
/// Handed to the `ServiceGroup` by whichever module provides the adapter —
/// the local core deliberately has no service (it is demand-driven).
///
/// Termination semantics: on graceful shutdown the relay is cancelled and
/// `run()` returns. If the adapter's incoming stream finishes on its own
/// (permanent connection loss — see the `DistributedPubSubAdapter` contract),
/// `run()` also returns, and the owning module's `serviceCompletion` policy
/// decides what that means for the app; the `FlightModule` default,
/// `.failsApp`, correctly treats a dead relay as an app failure.
public struct PubSubRelayService: Service, Sendable {

    private enum Source: Sendable {
        /// Resolve lazily in `run()` — the module wiring path, where the
        /// service is constructed pre-freeze (Core §7 collects services
        /// during configuration) and components exist only later.
        case container(Container)
        case clustered(ClusteredPubSub)
    }

    private let source: Source
    private let logger: Logger

    /// For module wiring: resolves the app's `any PubSub` component at start and
    /// requires it to be clustered.
    public init(container: Container, logger: Logger = Logger(label: "flight.pubsub.relay")) {
        self.source = .container(container)
        self.logger = logger
    }

    /// For direct embedding, bypassing the container.
    public init(clustered: ClusteredPubSub, logger: Logger = Logger(label: "flight.pubsub.relay")) {
        self.source = .clustered(clustered)
        self.logger = logger
    }

    public func run() async throws {
        let clustered: ClusteredPubSub
        switch source {
        case .clustered(let instance):
            clustered = instance
        case .container(let container):
            guard let resolved = try container.resolve((any PubSub).self) as? ClusteredPubSub else {
                throw PubSubWiringError.pubSubIsNotClustered
            }
            clustered = resolved
        }

        logger.info("pubsub relay running", metadata: ["node": "\(clustered.nodeID)"])
        await cancelWhenGracefulShutdown {
            await clustered.runIncomingRelay()
        }
        logger.info("pubsub relay stopped", metadata: ["node": "\(clustered.nodeID)"])
    }
}
