# Flight PubSub

Topic-based publish/subscribe for Flight: a publisher sends a `Message` to a
named topic; every subscriber to that topic receives it. That's the whole
surface. It is the bottom of the Live family (Channels, Presence, Live all
consume it) and the same distributed-coordination seam Flight Cloud's
multi-node story needs. Modeled on
`Phoenix.PubSub`.

- **Local core** (`LocalPubSub`) — production-ready now; the 90% case.
- **Distributed seam** (`DistributedPubSubAdapter`, `ClusteredPubSub`,
  `PubSubRelayService`) — ships now; concrete adapters (Redis first, then
  SWIM-native) are sequenced, per the design's maturity assessment.
- **No Web dependency** — usable by a headless app (job coordination, cache
  invalidation) with no HTTP at all.

## Usage

```swift
import FlightCore
import FlightPubSub

try await bootstrap(
    configuration: .load(),
    modules: [FlightPubSubModule.self, AppModule.self]
)

// Anywhere components are wired:
let pubsub = try container.resolve((any PubSub).self)

// Subscribe — subscription lifetime IS the consuming task's lifetime.
// Cancel the task, break out of the loop, or drop the stream, and the
// subscription is torn down; no manual unsubscribe exists to forget.
Task {
    for await message in pubsub.subscribe("room:42") {
        // decode message.payload — encoding is the caller's concern
    }
}

// Publish — fire-and-forget fan-out to current subscribers.
await pubsub.publish(Message(topic: "room:42", payload: data))
```

### What the clustered path costs, and what it drops

`publish` fans out locally first and unconditionally — local subscribers
never wait on, or fail with, the inter-node hop. The remote broadcast is
bounded by `broadcastTimeout` (5 seconds by default, `nil` to wait
forever): an adapter that stops answering costs one remote delivery, not
the publisher's liveness, and that holds whether or not the adapter responds
to cancellation.

Per message, though, not per publisher: `publish` returns only once the
broadcast has completed or timed out, which preserves wire ordering and means
a *sequential* publisher's next message waits on the previous one's remote
hop. Publisher throughput is therefore capped by adapter latency. Publish from
separate tasks if that matters more than ordering.

Under a bounded `BufferingPolicy`, a full subscriber buffer discards the
message — that is what at-most-once permits. `LocalPubSub.droppedCount` and
`droppedCounts` report how many, per topic, and each drop is logged with
the topic and a running total. Both are always zero under the default
`.unbounded` policy.

### Node identity

`nodeID` names a node for logs and operators. It does **not** have to be
unique and correctness does not depend on it: echo suppression matches on
`instanceToken`, generated per instance. Two nodes sharing a `nodeID`
deliver to each other normally, and the collision is logged once per
offending instance so an operator reading conflated logs finds out why.

Every reserved metadata key (`flight.pubsub.origin`,
`flight.pubsub.instance`) is stripped before delivery — on both the
receiving and the publishing node. A subscriber never sees transport
bookkeeping, and never sees a caller's imitation of it.

### Semantics (the contract)

| Property | Guarantee |
|---|---|
| Delivery | At-most-once, in-memory, fire-and-forget. No durability, no replay, no acks. |
| Ordering | Per-subscriber publish order for sequential publishes. No global order across topics/subscribers. |
| Topics | Exact-match strings, fully opaque (no parsing, no validation, no wildcards in v1). |
| Payload | Opaque `Data`; PubSub never encodes or decodes. |
| Registration | Effective when `subscribe` returns: a publish that happens-after subscribe is delivered. |
| Isolation | A slow subscriber buffers (or, under a bounded policy, drops) on its own; it never blocks the publisher or other subscribers. |

`LocalPubSub(bufferingPolicy:)` controls per-subscriber buffering:
`.unbounded` (default — BEAM-mailbox behavior, nothing dropped),
`.bufferingOldest(n)` / `.bufferingNewest(n)` for a memory ceiling at the
price of drops, which at-most-once semantics already permit.

Through the module, that and the cluster knobs are constructor arguments:

```swift
try await Flight.bootstrap(
    configuration: .load(),
    modules: [FlightPubSubModule(bufferingPolicy: .bufferingNewest(1024), nodeID: "api-3")]
)
```

They had to be, or they did not exist: the module used to hardcode
`LocalPubSub()`, the container's first registration wins, and a second one
fails `freeze()` — so an app bootstrapped through the module could not reach
a bounded policy at all.

## Multi-node

Consumers never change: they code against `any PubSub`. A deployment
becomes multi-node by registering a `DistributedPubSubAdapter` component —
`FlightPubSubModule`'s `any PubSub` factory then composes a `ClusteredPubSub`
around the same local core instead of returning it bare.

`ClusteredPubSub` stamps every outgoing broadcast with an origin-node ID
(reserved metadata key `flight.pubsub.origin`) and drops self-originated
arrivals, so echoing transports (Redis pub/sub echoes to the publishing
connection) still yield exactly-one local delivery. The stamp is stripped
before delivery: subscribers see identical metadata at zero hops or one.

### Writing an adapter module

An adapter package provides one `FlightModule` that:

1. registers its `(any DistributedPubSubAdapter).self` component,
2. declares `FlightPubSubModule.self` in `dependencies`,
3. exposes `PubSubRelayService(container:)` — composed with any connection
   service of its own — as its `service` (the local core has no service;
   the relay and the connection are the distributed deployment's
   long-running half).

`Tests/PubSub/FlightPubSubTests/ModuleTests.swift` contains a complete working
example (`InMemoryAdapterModule`), including two bootstrapped apps forming a
cluster and shutting down gracefully.

#### Firehose or per-topic

Two shapes, and the difference is scaling rather than correctness:

- **Firehose.** Carry everything on one wire channel and ignore the
  topic-interest callbacks — they default to no-ops. Every node receives
  every cluster message; a topic this node has no subscribers for costs one
  no-op inside `local.publish`. This is what `Phoenix.PubSub.Redis` does, and
  it is the right choice for most clusters.
- **Per-topic.** Implement `subscribed(to:)` / `unsubscribed(from:)` and
  `SUBSCRIBE`/`UNSUBSCRIBE` on the wire, so a node receives only what it has
  a subscriber for. Worth it when the topic space is large and each node
  cares about few of it — per-user or per-document topics, where a firehose
  makes every node's inbound traffic the whole cluster's outbound.

They fire on the *first* subscriber to a topic and the *last* unsubscribe
from it, not per subscriber, so "this node now needs / no longer needs this
topic" is exactly what an adapter is told — no debouncing. Neither is async:
they are called from `subscribe`'s synchronous body, which is what makes the
subscribe-effective-at-return guarantee possible, so an adapter doing I/O
should hand it to its own task. A message arriving for a topic this node has
since dropped is harmless: `local.publish` finds no subscribers.

Adapter contract (see `DistributedPubSubAdapter` docs): `broadcast` failures
throw and are logged-and-dropped by the composition; `incoming()` has a
single consumer and finishing it means the adapter is permanently done —
transient reconnection is the adapter's job, behind a stream that keeps
yielding.

## Testing support

`FlightPubSubTesting` ships:

- `InMemoryCluster` — an in-process wire connecting any number of adapters;
  `makeAdapter()` per node, optional `echoesToOrigin` to simulate Redis-style
  echo. Lets consumers test single-node and multi-node code paths without a
  network.
- `RecordingAdapter` — records broadcasts, injects incoming messages by
  hand, arms broadcast failures. For unit-testing clustered paths in
  isolation.

## Design deltas from the spec

Two implementation-mechanics deltas, both forced by the spec's own API
contract; observable semantics are exactly as specified.

1. **`Mutex`-guarded class, not an actor.** The
   protocol's `subscribe` is synchronous and must make registration effective
   at return (Presence-style "subscribe, then broadcast your own join" flows
   depend on it; `Phoenix.PubSub.subscribe` gives the same guarantee). An
   actor cannot mutate isolated state from a synchronous call — actor-backed
   registration would lag the returned stream and race the very next
   publish. The registry keeps the required serialized mutation, via the
   primitive that can do it synchronously (Core precedent: health tracking,
   `Scope`).

2. **No `AsyncChannel`** (the obvious choice for per-subscriber back-pressure,
   and the header listed swift-async-algorithms as a dependency). A
   rendezvous channel's send suspends until the consumer receives; awaiting
   that in `publish` blocks the publisher on the slowest subscriber — which
   the contract itself forbids — and pumping the channel into the returned
   `AsyncStream` just relocates the backlog into the stream's buffer,
   reducing the channel to decoration. Per-subscriber `AsyncStream` buffers
   with configurable policy deliver the stated behavior directly, and the
   package carries one fewer dependency.

## Building

PubSub is a target of the `flight` package, not a package of its own, so it
builds with the repository:

```
swift build --enable-all-traits
swift test  --enable-all-traits    # 60 PubSub tests across 9 suites
```

A plain `swift build` at the root fails by design — the trait-gated targets
find their dependencies pruned. Depends on `FlightCore`, `swift-log` and
`swift-service-lifecycle`. Linux and macOS 15+ (`Synchronization.Mutex`, the
same floor as Core).
