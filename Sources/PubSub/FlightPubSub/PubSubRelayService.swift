import FlightCore
import Logging
import ServiceLifecycle

/// Wiring errors surfaced at service start — misconfiguration, not runtime
/// conditions.

/// The long-running half of a distributed deployment: drains the
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
        /// The module wiring path: holds the `ClusteredPubSub` the module
        /// built at composition, and drains it in `run()`.
        case clustered(ClusteredPubSub)
    }

    private let source: Source
    private let logger: Logger

    /// The module holds the `ClusteredPubSub` and hands it over — it used to
    /// resolve `any PubSub` from a container and cast, which is gone with the
    /// container.
    public init(clustered: ClusteredPubSub, logger: Logger = Logger(label: "flight.pubsub.relay")) {
        self.source = .clustered(clustered)
        self.logger = logger
    }

    public func run() async throws {
        let clustered: ClusteredPubSub
        switch source {
        case .clustered(let instance):
            clustered = instance
        }

        logger.info("pubsub relay running", metadata: ["node": "\(clustered.nodeID)"])
        await cancelWhenGracefulShutdown {
            await clustered.runIncomingRelay()
        }
        logger.info("pubsub relay stopped", metadata: ["node": "\(clustered.nodeID)"])
    }
}
