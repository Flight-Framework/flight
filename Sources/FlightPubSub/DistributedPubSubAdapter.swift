/// Carries messages BETWEEN nodes (§5). The local `PubSub` (§2) handles
/// intra-node delivery; this handles inter-node relay. A single-node
/// deployment uses no adapter at all — the local core is complete on its own.
///
/// This is the pluggable seam. Concrete conformances are sequenced, not
/// shipped here (§5.1): Redis (`PUBLISH`/`SUBSCRIBE`) first as the pragmatic
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
/// - Echoing a node's own broadcasts back through `incoming()` is harmless:
///   `ClusteredPubSub` stamps every broadcast with an origin-node ID and
///   drops self-originated arrivals (Redis, notably, echoes to the
///   publishing connection's subscribers).
public protocol DistributedPubSubAdapter: Sendable {
    /// Relay a locally-published message to other nodes.
    func broadcast(_ message: Message) async throws

    /// Messages arriving FROM other nodes, to be delivered into THIS node's
    /// local PubSub.
    func incoming() -> AsyncStream<Message>
}
