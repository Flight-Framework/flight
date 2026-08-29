/// Carries messages BETWEEN nodes. The local `PubSub` handles
/// intra-node delivery; this handles inter-node relay. A single-node
/// deployment uses no adapter at all — the local core is complete on its own.
///
/// This is the pluggable seam. Concrete conformances are sequenced, not
/// shipped here: Redis (`PUBLISH`/`SUBSCRIBE`) first as the pragmatic
/// option, a SWIM-membership + NIO relay as the strategic native option, a
/// `swift-distributed-actors` adapter if/when it reaches a stable 1.0.
/// `ClusteredPubSub` composes any of them identically; nothing above the
/// seam changes when you swap.
///
/// ## Contract for adapter authors
///
/// - `broadcast` may be called concurrently and must be safe to do so.
///   Failures should throw; `ClusteredPubSub` logs and drops (at-most-once —
///   a lost broadcast is a permitted outcome, never a crashed publisher).
/// - `incoming()` has a **single consumer**: the relay loop
///   (`PubSubRelayService` / `ClusteredPubSub.runIncomingRelay`). It is
///   called once per adapter lifetime; adapters need not support fan-out of
///   this stream.
/// - The stream **finishing means the adapter is done for good** (connection
///   permanently lost, cluster left). Transient reconnection is the
///   adapter's job, invisible behind a stream that simply keeps yielding.
/// - **`Message.metadata` must round-trip unchanged.** The keys under
///   `flight.pubsub.` are how a node recognizes its own echo and how a
///   broadcast's origin is known at the far end; an adapter that serializes
///   only topic and payload turns every echo into a duplicate delivery. This
///   was left unsaid while echo suppression quietly depended on it.
/// - Echoing a node's own broadcasts back through `incoming()` is harmless
///   *given* that round-trip: `ClusteredPubSub` stamps every broadcast with
///   an origin-node ID and drops self-originated arrivals (Redis, notably,
///   echoes to the publishing connection's subscribers).
/// - `broadcast` need not respond to cancellation. `ClusteredPubSub`'s
///   `broadcastTimeout` bounds the publisher regardless — it used to depend
///   on cooperation the contract never asked for, so an adapter blocked in
///   non-cancellable work hung every publish despite the timeout.
///
/// ## Topic interest, and the two adapter shapes
///
/// An adapter may be written either way, and the difference is a scaling
/// one rather than a correctness one:
///
/// - **Firehose.** Ignore ``subscribed(to:)``/``unsubscribed(from:)`` — they
///   default to no-ops — and carry every message on one wire channel. Every
///   node receives every cluster message; topics this node has no subscribers
///   for cost one no-op inside `local.publish`. This is the shape
///   `Phoenix.PubSub.Redis` takes, and it is the right one for most clusters.
/// - **Per-topic.** Use those callbacks to `SUBSCRIBE`/`UNSUBSCRIBE` on the
///   wire, so a node receives only what it has a subscriber for. Worth it
///   when the topic count is large and each node cares about few of them —
///   a per-user or per-document topic space, where the firehose makes every
///   node's inbound traffic the whole cluster's outbound.
///
/// The callbacks fire on the *first* subscriber to a topic and the *last*
/// unsubscribe from it, not per subscriber, so an adapter can treat them as
/// "this node now needs / no longer needs this topic" directly. Neither is
/// async: they are called from `subscribe`'s synchronous body, which is what
/// makes the subscribe-effective-at-return guarantee possible, so an adapter
/// that must do I/O should hand the work to its own task and let ordering be
/// its concern. A message arriving for a topic this node has since dropped is
/// harmless — `local.publish` finds no subscribers.
public protocol DistributedPubSubAdapter: Sendable {
    /// Relay a locally-published message to other nodes.
    func broadcast(_ message: Message) async throws

    /// Messages arriving FROM other nodes, to be delivered into THIS node's
    /// local PubSub.
    func incoming() -> AsyncStream<Message>

    /// This node has gained its first subscriber for `topic`.
    ///
    /// Optional: the default does nothing, which is exactly right for a
    /// firehose adapter. See "Topic interest, and the two adapter shapes".
    func subscribed(to topic: String)

    /// This node has lost its last subscriber for `topic`.
    func unsubscribed(from topic: String)
}

extension DistributedPubSubAdapter {
    /// Firehose adapters need neither, so neither is a requirement — adding
    /// them as one would have broken every adapter written before they
    /// existed, for a capability most adapters do not want.
    public func subscribed(to topic: String) {}
    public func unsubscribed(from topic: String) {}
}

/// What `LocalPubSub` tells its owner about topics gaining and losing
/// subscribers. `ClusteredPubSub` is the only implementation; it forwards to
/// the adapter.
internal protocol TopicInterestObserver: Sendable {
    func topicGainedInterest(_ topic: String)
    func topicLostInterest(_ topic: String)
}
