# Flight PubSub

Topic-based publish/subscribe for Flight: a publisher sends a `Message` to a
named topic; every subscriber to that topic receives it. That's the whole
surface. It is the bottom of the Live family (Channels, Presence, Live all
consume it) and the same distributed-coordination seam Flight Cloud's
multi-node story needs. Design: `../flight-pubsub-design.md`; modeled on
`Phoenix.PubSub`.

- **Local core** (`LocalPubSub`) — production-ready now; the 90% case.
- **Distributed seam** (`DistributedPubSubAdapter`, `ClusteredPubSub`,
  `PubSubRelayService`) — ships now; concrete adapters (Redis first, then
  SWIM-native) are sequenced, per the design's maturity assessment (§5.1).
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

### Semantics (the contract, §3/§8)

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

## Multi-node

Consumers never change: they code against `any PubSub` (§5). A deployment
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
   service of its own — as its `service` (§6: the local core has no service;
   the relay and the connection are the distributed deployment's
   long-running half).

`Tests/FlightPubSubTests/ModuleTests.swift` contains a complete working
example (`InMemoryAdapterModule`), including two bootstrapped apps forming a
cluster and shutting down gracefully.

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

1. **`Mutex`-guarded class, not an actor** (§2.2 named an actor). The
   protocol's `subscribe` is synchronous and must make registration effective
   at return (Presence-style "subscribe, then broadcast your own join" flows
   depend on it; `Phoenix.PubSub.subscribe` gives the same guarantee). An
   actor cannot mutate isolated state from a synchronous call — actor-backed
   registration would lag the returned stream and race the very next
   publish. The registry keeps the required serialized mutation, via the
   primitive that can do it synchronously (Core precedent: health tracking,
   `Scope`).

2. **No `AsyncChannel`** (§2.2 named it for per-subscriber back-pressure,
   and the header listed swift-async-algorithms as a dependency). A
   rendezvous channel's send suspends until the consumer receives; awaiting
   that in `publish` blocks the publisher on the slowest subscriber — which
   §2.2 itself forbids — and pumping the channel into the returned
   `AsyncStream` just relocates the backlog into the stream's buffer,
   reducing the channel to decoration. Per-subscriber `AsyncStream` buffers
   with configurable policy deliver the stated behavior directly, and the
   package carries one fewer dependency.

## Building

```
swift build
swift test    # 44 tests across 6 suites
```

Depends on `flight-core` (path), `swift-log`, `swift-service-lifecycle`.
Linux and macOS 15+ (`Synchronization.Mutex`, same floor as flight-core).
