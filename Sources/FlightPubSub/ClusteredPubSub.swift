import Synchronization
import Foundation
import Logging

/// The clustered composition: wraps the local `PubSub` and a
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
    /// this key are overwritten on broadcast and stripped on delivery —
    /// including local delivery on the publishing node.
    public static let originMetadataKey = "flight.pubsub.origin"

    /// Reserved metadata key carrying this *instance's* token, which is what
    /// echo suppression actually matches on. See ``nodeID``.
    public static let instanceMetadataKey = "flight.pubsub.instance"

    /// Identifies this node within the cluster, for logs and operators.
    ///
    /// Duplicate suppression does **not** key on this. Two nodes configured
    /// with the same `nodeID` — a copy-pasted config, a scaled deployment
    /// that templates a constant — each treated the other's messages as
    /// their own echo and dropped them, so the two nodes went totally deaf
    /// to each other, in both directions, silently. Suppression keys on
    /// ``instanceToken`` instead, which is generated per instance and cannot
    /// collide, and a `nodeID` collision is now something this type notices
    /// and logs rather than something that quietly breaks delivery.
    public let nodeID: String

    /// Unique per instance, always. The value echo suppression matches.
    public let instanceToken: String

    private let local: LocalPubSub
    private let adapter: any DistributedPubSubAdapter
    private let logger: Logger
    private let broadcastTimeout: Duration?
    private let reportedCollisions = Mutex(Set<String>())

    /// - Parameters:
    ///   - local: In-process delivery. Every publish reaches these
    ///     subscribers first and synchronously, whatever the adapter does.
    ///   - adapter: The cluster hop — what carries a publish to the other
    ///     nodes and delivers theirs back. The Valkey adapter in
    ///     `flight-data` is one; the protocol is narrow enough to write
    ///     another.
    ///   - nodeID: A human-meaningful name for this node. Need not be
    ///     unique; correctness does not depend on it.
    ///   - broadcastTimeout: How long `publish` will wait on the adapter
    ///     before giving up on the remote hop. Local delivery has already
    ///     happened by then and is unaffected. `nil` waits forever, which is
    ///     what this used to do unconditionally — an adapter that stopped
    ///     answering blocked every publisher in the process indefinitely.
    ///   - logger: Where the relay reports adapter failures and topic
    ///     collisions. These are the only places a clustered publish
    ///     differs observably from a local one.
    public init(
        local: LocalPubSub,
        adapter: any DistributedPubSubAdapter,
        nodeID: String = UUID().uuidString,
        broadcastTimeout: Duration? = .seconds(5),
        logger: Logger = Logger(label: "flight.pubsub.clustered")
    ) {
        self.local = local
        self.adapter = adapter
        self.nodeID = nodeID
        self.instanceToken = UUID().uuidString
        self.broadcastTimeout = broadcastTimeout
        self.logger = logger
    }

    public func publish(_ message: Message) async {
        // Local fan-out first and unconditionally: subscribers on this node
        // never wait on, or fail with, the inter-node relay.
        //
        // Reserved keys are stripped here too. They used to be overwritten
        // only on the outgoing copy, so a caller who put a value under the
        // origin key had it delivered verbatim to subscribers on this node —
        // the one place the documented "stripped on delivery" guarantee did
        // not hold, and the place where a forged value would be believed.
        await local.publish(stripping(message))

        var metadata = message.metadata
        metadata[Self.originMetadataKey] = nodeID
        metadata[Self.instanceMetadataKey] = instanceToken
        let stamped = Message(topic: message.topic, payload: message.payload, metadata: metadata)
        do {
            try await broadcast(stamped)
        } catch is BroadcastTimeout {
            // At-most-once: a slow adapter costs a remote delivery, not the
            // publisher's liveness.
            logger.warning(
                "distributed broadcast timed out; local delivery unaffected",
                metadata: [
                    "topic": "\(message.topic)",
                    "timeout": "\(broadcastTimeout.map(String.init(describing:)) ?? "none")",
                ]
            )
        } catch {
            // A failed broadcast is a dropped remote delivery, not a
            // publisher error. Log loudly and move on.
            logger.warning(
                "distributed broadcast failed; local delivery unaffected",
                metadata: ["topic": "\(message.topic)", "error": "\(error)"]
            )
        }
    }

    private struct BroadcastTimeout: Error {}

    /// Broadcasts, giving up after ``broadcastTimeout``.
    private func broadcast(_ message: Message) async throws {
        guard let broadcastTimeout else {
            try await adapter.broadcast(message)
            return
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await self.adapter.broadcast(message) }
            group.addTask {
                try await Task.sleep(for: broadcastTimeout)
                throw BroadcastTimeout()
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }

    /// Strips every reserved key, so subscribers never see transport
    /// bookkeeping and never see a caller's imitation of it.
    private func stripping(_ message: Message) -> Message {
        var metadata = message.metadata
        // Both removals run: `||` would short-circuit past the second one
        // whenever the first key was present, leaving the instance token on
        // the message.
        let hadOrigin = metadata.removeValue(forKey: Self.originMetadataKey) != nil
        let hadInstance = metadata.removeValue(forKey: Self.instanceMetadataKey) != nil
        guard hadOrigin || hadInstance else { return message }
        return Message(topic: message.topic, payload: message.payload, metadata: metadata)
    }

    public func subscribe(_ topic: String) -> AsyncStream<Message> {
        local.subscribe(topic)
    }

    /// Drains `adapter.incoming()` into local fan-out. Runs until the
    /// adapter's stream finishes or the surrounding task is cancelled —
    /// normally hosted by `PubSubRelayService` under the app's
    /// `ServiceGroup`; public for embedders managing their own tasks.
    public func runIncomingRelay() async {
        for await message in adapter.incoming() {
            let origin = message.metadata[Self.originMetadataKey]
            let instance = message.metadata[Self.instanceMetadataKey]

            // Suppress on the instance token, which cannot collide.
            if let instance {
                if instance == instanceToken {
                    continue  // our own broadcast, echoed back — already delivered locally
                }
            } else if origin == nodeID {
                // No instance token: an adapter that does not carry metadata
                // round-trip, or a node from before the token existed. Fall
                // back to the node name and suppress, because a duplicate
                // local delivery is the failure this stamping exists to
                // prevent and there is nothing better to go on.
                continue
            }

            // A message from elsewhere wearing our node name means two nodes
            // share a nodeID. Suppression is unaffected, but an operator
            // reading logs or metrics is about to be misled, so say it once
            // per offending instance rather than on every message.
            if let origin, origin == nodeID, let instance {
                let unreported = reportedCollisions.withLock { $0.insert(instance).inserted }
                if unreported {
                    logger.error(
                        "another node is using this node's ID; logs and metrics will conflate them",
                        metadata: ["node": "\(nodeID)", "other-instance": "\(instance)"]
                    )
                }
            }

            await local.publish(stripping(message))
        }
        logger.debug("adapter incoming stream finished; relay ending", metadata: ["node": "\(nodeID)"])
    }
}
