import struct Foundation.UUID
import Logging
import Synchronization

/// The in-process pub/sub core: a registry of topics to subscribers,
/// delivering messages concurrency-safely. Complete on its own for a
/// single-node deployment; the local half of a clustered one.
///
/// ## Concurrency model — a deliberate choice worth explaining
///
/// The doc reserves an `actor` for the registry and `AsyncChannel` for
/// per-subscriber delivery. Implementing against this type's *own API contract*
/// forces two changes, both recorded in `Docs/pubsub.md`:
///
/// 1. **`Mutex`-guarded class, not an actor.** `subscribe(_:)` is synchronous
///    and must guarantee "a publish that happens-after subscribe is
///    delivered" (see `PubSub` — Presence-style join flows rely on it, and
///    `Phoenix.PubSub.subscribe` gives the same guarantee). An actor cannot
///    mutate isolated state from a synchronous call, so actor-backed
///    registration would lag the returned stream and race the very next
///    publish. The registry is instead serialized by a `Mutex` — the same
///    "genuinely mutable shared state, serialized mutation" requirement,
///    met with the primitive that can do it synchronously (precedent:
///    Core's health tracking and `Scope`).
///
/// 2. **Per-subscriber `AsyncStream` buffers, not `AsyncChannel`.** An
///    `AsyncChannel` send suspends until the consumer receives — real
///    back-pressure, but pressure on *whoever awaits the send*. Awaiting it
///    in `publish` blocks the publisher on the slowest subscriber, which
///    the contract itself forbids; bridging the channel into the returned
///    `AsyncStream` via a pumping task just moves the backlog into the
///    stream's unbounded buffer and reduces the channel to decoration.
///    Per-subscriber buffering with a configurable `BufferingPolicy` yields
///    the stated observable semantics directly: a slow subscriber's backlog
///    is its own (bounded, with drops — at-most-once permits that — or
///    unbounded, the Phoenix-mailbox default) and never blocks the publisher
///    or other subscribers.
public final class LocalPubSub: PubSub, Sendable {

    /// How each subscriber's pending messages buffer between publish and
    /// consumption. `.unbounded` (the default) mirrors a BEAM process
    /// mailbox: nothing is ever dropped, memory is the limit. Bounded
    /// policies (`.bufferingOldest(n)` drops new messages when full,
    /// `.bufferingNewest(n)` evicts the oldest) trade completeness for a
    /// memory ceiling — a legitimate at-most-once trade.
    public typealias BufferingPolicy = AsyncStream<Message>.Continuation.BufferingPolicy

    private struct Registry {
        var topics: [String: [UUID: AsyncStream<Message>.Continuation]] = [:]
    }

    private let registry = Mutex(Registry())
    private let bufferingPolicy: BufferingPolicy
    private let dropped = Mutex([String: Int]())
    private let logger: Logger

    public init(
        bufferingPolicy: BufferingPolicy = .unbounded,
        logger: Logger = Logger(label: "flight.pubsub.local")
    ) {
        self.bufferingPolicy = bufferingPolicy
        self.logger = logger
    }

    /// Messages a bounded buffer refused, per topic, since this instance
    /// started.
    ///
    /// Always empty under the default `.unbounded` policy. Under a bounded
    /// one, a full subscriber buffer silently discarded the message and
    /// nothing recorded it — `yield` returns a result saying so and it was
    /// thrown away, so the one signal that a subscriber was falling behind
    /// went nowhere. At-most-once permits the drop; it does not require
    /// hiding it.
    public var droppedCounts: [String: Int] {
        dropped.withLock { $0 }
    }

    /// Total messages a bounded buffer refused since this instance started.
    public var droppedCount: Int {
        dropped.withLock { $0.values.reduce(0, +) }
    }

    public func publish(_ message: Message) async {
        // Snapshot under the lock, yield outside it: yields are non-blocking
        // and thread-safe, and keeping them out of the critical section means
        // a large fan-out never stalls concurrent (un)subscribes.
        let subscribers = registry.withLock { state in
            state.topics[message.topic].map { Array($0.values) } ?? []
        }
        var refused = 0
        for continuation in subscribers {
            // The result is the only evidence a bounded buffer was full.
            switch continuation.yield(message) {
            case .enqueued, .terminated:
                break
            case .dropped:
                refused += 1
            @unknown default:
                break
            }
        }
        guard refused > 0 else { return }

        let total = dropped.withLock { counts in
            counts[message.topic, default: 0] += refused
            return counts[message.topic] ?? refused
        }
        logger.warning(
            "subscriber buffer full; message dropped",
            metadata: [
                "topic": "\(message.topic)",
                "dropped-now": "\(refused)",
                "dropped-total-for-topic": "\(total)",
            ]
        )
    }

    public func subscribe(_ topic: String) -> AsyncStream<Message> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(
            of: Message.self,
            bufferingPolicy: bufferingPolicy
        )
        registry.withLock { state in
            state.topics[topic, default: [:]][id] = continuation
        }
        // Fires on consumer-task cancellation, on the stream being dropped
        // without full consumption, and on finish — every way a subscription
        // ends. This is the "no manual unsubscribe bookkeeping" contract
        //. Safe to set after registration: if termination already
        // happened, the handler runs immediately.
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            self.registry.withLock { state in
                state.topics[topic]?[id] = nil
                if state.topics[topic]?.isEmpty == true {
                    state.topics[topic] = nil
                }
            }
        }
        return stream
    }

    // MARK: - Introspection

    /// Current number of live subscriptions to `topic`. Observational —
    /// the value can change the moment it is read; useful for diagnostics
    /// and tests, not for coordination.
    public func subscriberCount(for topic: String) -> Int {
        registry.withLock { $0.topics[topic]?.count ?? 0 }
    }

    /// Number of topics with at least one live subscriber. Topic entries are
    /// removed eagerly when their last subscriber leaves, so this also
    /// verifies the registry cannot grow without bound under topic churn.
    public var activeTopicCount: Int {
        registry.withLock { $0.topics.count }
    }
}
