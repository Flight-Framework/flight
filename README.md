# Flight Presence

"Who is currently connected to this topic," kept correct across every node
in a cluster — Phoenix Presence's analogue, built on the two layers below
it: **PubSub** carries presence state between nodes, **Channels** owns the
per-connection lifecycle and delivers updates to clients. Presence adds the
conflict-free merge semantics and the diffing that make a distributed
"who's here" list correct without central coordination
(`../flight-presence-design.md`).

## The model in one paragraph

One identity may be present many times: a user with three browser tabs is
one **key** with three **metas** (§2). Closing one tab removes one meta;
only the *last* meta's removal is a leave of the key. Every node holds the
whole cluster's presence state in an ORSWOT-style delta-state CRDT (§4):
adds are tagged `(replica, counter)`, removes remove exactly the observed
tags, and merge is commutative, associative, and idempotent — so reordered
or duplicated gossip is harmless and replicas converge without a leader,
locks, or synchronized clocks.

## Using it

```swift
struct AppModule: FlightModule {
    static var dependencies: [any FlightModule.Type] { [FlightPresenceModule.self] }

    func configure(_ container: Container) throws {
        container.registerChannel("room:*") { c in
            RoomChannel(presence: try c.resolve((any Presence).self))
        }
        container.registerChannelSocket("/socket") { context in
            context.request.queryParam("token").map { try verify($0) }
        }
    }
}

struct RoomChannel: Channel {
    let presence: any Presence

    func join(_ topic: String, socket: Socket) async -> JoinResult {
        guard let user = socket.principal?.subject else { return .reject(.unauthenticated) }
        await presence.track(topic: topic, key: user, payload: ["status": "online"], socket: socket)
        await presence.sendState(topic: topic, to: socket)   // §6: state, then diffs
        return .ok
    }

    func handle(_ event: InboundEvent, socket: Socket) async -> HandleResult {
        if event.event == "status", let user = socket.principal?.subject,
            let status = event.payload["status"]?.stringValue {
            await presence.update(topic: event.topic, key: user, payload: ["status": status], socket: socket)
            return .reply(.object([:]))
        }
        return .none
    }
}
```

Untracking is **automatic and structural** (§7): a presence is tracked
against the socket's membership of the topic. Client leave, transport
drop, heartbeat timeout, server shutdown — every teardown path removes the
metas and broadcasts the leave diff. There is nothing to remember to call.
(`untrack` exists for the rare "stop appearing present, stay in the room".)

Clients receive one `flight:presence_state` on join, then
`flight:presence_diff`s (§6). Both reference clients ship a helper that
maintains the list from those messages:

- **Swift:** `FlightPresenceClient` — `ChannelPresence(channel:)`, an
  `AsyncStream` of changes.
- **JS/TS:** `@flight/channels/presence` — `new FlightPresence(channel)`,
  `onChange(({list, joins, leaves}) => …)`.

Both normalize meta updates (a leave+join of the same `ref`) into in-place
changes — no flap — and share one rulebook, asserted by twin test suites
(`PresenceSyncTests` / `presence.test.js`).

## Failure-detection modes (§5)

Decided at freeze from what the container holds, and **logged loudly at
startup**:

| Deployment | Mode | Behavior |
| --- | --- | --- |
| No `DistributedPubSubAdapter` | `single-node` | No gossip at all; node failure is not a distributed concern. |
| Adapter + `PresenceMembershipMonitor` | `membership-aware` | The intended multi-node mode (§5.1). The monitor (the SWIM adapter, PubSub §5.1) declares a node down ⇒ its entries leave promptly, in one operation. Gossip from a down-declared node is ignored until the monitor says up — the monitor is authoritative. |
| Adapter only (Valkey-style fan-out) | `heartbeat-expiry` (**degraded**, §5.2) | Each node re-announces its own state every `heartbeat-interval`; a replica silent past `down-after` is hidden (leaves pushed). Removal is delayed up to the timeout; a slow node may flap; heartbeat traffic scales with state size. Logged at **warning** level so nobody discovers this from a bug report. |

In both clustered modes, a down replica's state is kept (hidden) until
`permdown-after`, so a wrongly-evicted node that resumes gossiping comes
back as joins with nothing lost; only then is it purged. Restart safety is
structural: a replica id is `(node-name, boot-id)` and boot ids never
recur, so a restarted node can never collide with its previous life's
counters.

The periodic own-state snapshot doubles as **anti-entropy** in membership
mode: PubSub is at-most-once, and the snapshot join repairs any dropped
delta (a missed add appears, a missed remove disappears).

### Configuration

Under the usual dotted namespace (all optional):

| Key | Default | |
| --- | --- | --- |
| `flight.presence.node-name` | generated | Stable node name; must match the membership monitor's vocabulary. Set it in any monitored deployment. |
| `flight.presence.heartbeat-interval-seconds` | 5 | Re-announce / anti-entropy cadence. |
| `flight.presence.down-after-seconds` | 15 | Degraded mode: silence ⇒ hidden. Must exceed the heartbeat interval (validated at bootstrap). |
| `flight.presence.permdown-after-seconds` | 300 | Continuously down ⇒ purged. |
| `flight.presence.sweep-interval-seconds` | `down-after / 4` | Liveness sweep cadence. |

## Wiring (§9)

`FlightPresenceModule` depends on `FlightPubSubModule` and
`FlightChannelsModule`; registers `PresenceConfiguration`,
`PresenceTracker` + `(any Presence)`, and contributes `PresenceService` to
the app `ServiceGroup` (gossip intake, heartbeats, liveness sweep,
membership events). A membership-aware adapter module registers its
monitor as `(any PresenceMembershipMonitor).self`; Presence detects it by
presence, the same composition rule as PubSub's adapter seam.

## Scaling limits (§8) — inherent, not implementation defects

State is O(connections) per topic, replicated to every node; diff traffic
is O(members × change rate). Presence works well for many moderate topics
and poorly for one enormous one — shard huge topics explicitly
(`room:42:shard:n`), or use a counter if a count is all you need. No
automatic sharding, deliberately: an abstraction that fails silently at
scale is worse than an honest limit.

## Design deltas (implementation vs. the design doc)

- **One gossip topic, not `flight:presence:<topic>`.** PubSub is
  exact-match with no wildcards (PubSub §3), and every node needs all
  presence gossip (§8's full replication), so per-channel-topic gossip
  topics are unsubscribable in aggregate. Gossip rides one reserved topic,
  `flight:presence`, with per-topic payloads inside — still "PubSub's
  existing fan-out machinery, no transport of Presence's own" (§4).
- **The Channels seam is explicit.** The design's "untracking is automatic
  when the connection's Scope closes" (§7) is realized through two small
  `@_spi(FlightInternal)` additions to `FlightChannels.Socket` —
  `onTopicActivated`/`onTopicTerminated` (driven by `SocketSession` on
  join/leave/teardown) and `pushReserved` (single-socket delivery of
  reserved `flight:*` events). Application code cannot reach either
  without a deliberate SPI import. `onTopicActivated` also removes the
  state/diff race: the state push runs only after the join's PubSub
  subscription is live, so the client sees reply → state → diffs with no
  gap a change could fall through.
- **`Presence` gains `untrack` and `sendState`** beyond the design's three
  methods (§3): `sendState` is the explicit trigger for §6's initial state
  message (watch-only members call it alone); `untrack` mirrors Phoenix.
- **Diffs are local-only traffic.** Every node computes identical diffs
  from its own replica's transitions and publishes them to its *local*
  PubSub; broadcasting them cluster-wide would deliver every diff N times.
  Only gossip crosses the wire.
- **Down is an overlay, not a delete.** §5.2's flap ("wrongly evicted,
  reappears when gossip resumes") requires keeping a down replica's state
  hidden rather than deleting it — an ORSWOT can't re-admit dots its
  context has observed. Deletion happens only at permdown, when the
  replica's context is forgotten wholesale (safe: boot ids never recur).

## Testing (§10)

`swift test` — 61 tests (the convergence properties alone cover 120
randomized cases):

- **Local semantics** (`TrackerTests`, `PresenceSyncTests`): metas per
  key, leave only on last meta, diff generation, update normalization.
- **CRDT convergence** (`CRDTConvergenceTests`): the §4 claim asserted as
  a *property* — 120 randomized cases of reordered, duplicated, and
  dropped-then-snapshot-repaired gossip across simulated replicas, every
  failure reproducible by seed; plus commutativity/associativity/
  idempotence checks.
- **Node failure** (`MultiNodeTests`): two full Flight apps over an
  in-memory cluster wire — prompt eviction in membership mode, delayed
  eviction and flap recovery in degraded mode, startup sync, permdown
  purge.
- **The wire** (`IntegrationTests`, `ClientHelperTests`): join ⇒ reply
  then state then diffs, through the real upgrade/session/PubSub stack.
