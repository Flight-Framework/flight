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
/// ## What the seam does not carry
///
/// There is no topic-interest signal: no hook fires on subscribe or
/// unsubscribe, so an adapter cannot subscribe per topic on the wire. A
/// single-channel firehose works — every node receives every cluster message
/// and non-subscribed topics no-op inside `local.publish`, which is the shape
/// `Phoenix.PubSub.Redis` takes — and is what the seam is designed for. On a
/// large cluster with many topics that is a fan-in ceiling, and lifting it
/// means changing this protocol rather than working around it.
public protocol DistributedPubSubAdapter: Sendable {
    /// Relay a locally-published message to other nodes.
    func broadcast(_ message: Message) async throws

    /// Messages arriving FROM other nodes, to be delivered into THIS node's
    /// local PubSub.
    func incoming() -> AsyncStream<Message>
}
