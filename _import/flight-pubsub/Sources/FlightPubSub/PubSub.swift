/// Topic-based publish/subscribe. This is the whole surface: consumers
/// (Channels, Presence, Live) code against this protocol and never know
/// whether they are on one node or twenty.
///
/// Semantics (the non-goals, stated positively):
/// - **At-most-once, in-memory, fire-and-forget.** A subscriber not present
///   when a message is published does not receive it. No durability, no
///   acknowledgements — consumers needing stronger guarantees build them on
///   top.
/// - **Per-subscriber publish order.** Within a single subscriber's stream,
///   messages from sequential publishes arrive in publish order. Across
///   topics or subscribers no global order is promised.
/// - **Exact-match topics**. No wildcards in v1.
public protocol PubSub: Sendable {
    /// Fan `message` out to every current subscriber of `message.topic`.
    ///
    /// Never throws and never blocks on a slow subscriber: delivery failure
    /// modes (a full bounded buffer, a dead remote node) degrade to dropped
    /// messages, which at-most-once semantics already permit.
    func publish(_ message: Message) async

    /// Subscribe to a topic. The returned stream yields messages until the
    /// caller stops iterating / the task is cancelled — structured-concurrency
    /// native, no manual unsubscribe bookkeeping required.
    ///
    /// Registration is effective when `subscribe` returns: a publish that
    /// happens-after `subscribe(_:)` is delivered to the new subscriber. The
    /// layers above rely on this (a Presence join subscribes, then broadcasts
    /// its own arrival, and must observe it).
    func subscribe(_ topic: String) -> AsyncStream<Message>
}
