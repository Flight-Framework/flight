import Foundation
import Logging

/// The clustered composition (§5): wraps the local `PubSub` and a
/// `DistributedPubSubAdapter`. On `publish` it does both local fan-out *and*
/// `adapter.broadcast`; the relay loop feeds `adapter.incoming()` back into
/// local fan-out. Consumers code against `PubSub` and never know whether
/// they're on one node or twenty — that transparency is the entire point of
/// the seam.
///
/// ## Origin stamping
///
/// Every outgoing broadcast is stamped with this node's ID under
/// `originMetadataKey`, and every incoming message carrying our own ID is
/// dropped. This makes duplicate-suppression a property of the composition,
/// not a burden on adapters: an adapter that echoes broadcasts back to the
/// publishing node (Redis does) still yields exactly-one local delivery.
/// The stamp is stripped before local delivery, so subscribers see identical
/// metadata whether a message travelled zero hops or one.
public final class ClusteredPubSub: PubSub, Sendable {

    /// Reserved metadata key (`flight.pubsub.origin`) carrying the
    /// originating node's ID across the wire. Caller-supplied values under
    /// this key are overwritten on broadcast and stripped on delivery.
    public static let originMetadataKey = "flight.pubsub.origin"

    /// Identifies this node within the cluster for duplicate suppression.
    /// Unique per `ClusteredPubSub` instance by default; supply one for
    /// stable identity in logs.
    public let nodeID: String

    private let local: LocalPubSub
    private let adapter: any DistributedPubSubAdapter
    private let logger: Logger

    public init(
        local: LocalPubSub,
        adapter: any DistributedPubSubAdapter,
        nodeID: String = UUID().uuidString,
        logger: Logger = Logger(label: "flight.pubsub.clustered")
    ) {
        self.local = local
        self.adapter = adapter
        self.nodeID = nodeID
        self.logger = logger
    }

    public func publish(_ message: Message) async {
        // Local fan-out first and unconditionally: subscribers on this node
        // never wait on, or fail with, the inter-node relay.
        await local.publish(message)

        var metadata = message.metadata
        metadata[Self.originMetadataKey] = nodeID
        let stamped = Message(topic: message.topic, payload: message.payload, metadata: metadata)
        do {
            try await adapter.broadcast(stamped)
        } catch {
            // At-most-once (§8): a failed broadcast is a dropped remote
            // delivery, not a publisher error. Log loudly and move on.
            logger.warning(
                "distributed broadcast failed; local delivery unaffected",
                metadata: ["topic": "\(message.topic)", "error": "\(error)"]
            )
        }
    }

    public func subscribe(_ topic: String) -> AsyncStream<Message> {
        local.subscribe(topic)
    }

    /// Drains `adapter.incoming()` into local fan-out. Runs until the
    /// adapter's stream finishes or the surrounding task is cancelled —
    /// normally hosted by `PubSubRelayService` under the app's
    /// `ServiceGroup` (§6); public for embedders managing their own tasks.
    public func runIncomingRelay() async {
        for await message in adapter.incoming() {
            guard message.metadata[Self.originMetadataKey] != nodeID else {
                continue  // our own broadcast, echoed back — already delivered locally
            }
            var metadata = message.metadata
            metadata.removeValue(forKey: Self.originMetadataKey)
            await local.publish(
                Message(topic: message.topic, payload: message.payload, metadata: metadata)
            )
        }
        logger.debug("adapter incoming stream finished; relay ending", metadata: ["node": "\(nodeID)"])
    }
}
