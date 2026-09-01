# Flight Channels

The stateful protocol layer between a raw WebSocket and topic-based
messaging: clients join named topics, exchange messages bidirectionally with
per-topic server handler logic, and receive fan-out from anything that
publishes to those topics. Scope modeled on Phoenix Channels, wire protocol
Flight's own.

It sits exactly between two things that already exist:

- **Below:** Flight Web's `WebSocketUpgradeHandler` owns the raw WebSocket.
  Channels is one.
- **Beside:** Flight PubSub does the fan-out. Channels routes and frames;
  PubSub delivers — on one node or twenty, invisibly.

What Channels adds is the per-connection, per-topic session protocol:
join/leave, routing to handlers, replies, heartbeats, reconnection.

## Targets

| Product | What | Depends on |
|---|---|---|
| `FlightChannels` | Server: `Channel`, `Socket`, `ChannelRouter`, `ChannelBroadcaster`, `ChannelSocketHandler`, `FlightChannelsModule` | Core, PubSub, Web |
| `FlightChannelsProtocol` | The wire protocol alone: `Envelope`, `JSONValue`, reserved events, error reasons, close codes | nothing |
| `FlightChannelsClient` | Swift reference client: `ChannelClient`, `ChannelHandle`, transport seam, reconnect-with-backoff-and-rejoin | Protocol, swift-log |
| `FlightChannelsTesting` | `InMemoryChannelTransport` (client ↔ in-process server, no socket), `ChannelWireClient` (raw-envelope driver) | the above + WebTesting |

The JS/TS reference client is
[flight-channels-js](https://github.com/Flight-Framework/flight-channels-js)
(`@flight-framework/channels` on npm) — same protocol, same versioning.

## Backpressure and blast radius

A socket's outbound queue is bounded by
`flight.channels.outbound-buffer-size` (256 by default). It used to be
unbounded: a client that stopped reading — a backgrounded tab, a wedged
connection, a phone in a tunnel — accumulated every message published to its
topics with no ceiling, so one stalled subscriber could exhaust the server's
memory while the watchdog waited out a 60-second heartbeat timeout.

Full means the **oldest** messages go, not the newest: a client behind on a
realtime feed wants current state, not a backlog it can never catch up on.
Drops are counted per socket (`Socket.droppedEnvelopeCount`) and logged, so a
subscriber falling behind is visible rather than silent.

Nothing in the request path calls `precondition` any more. A reserved event
name reaching `push`, `pushReserved`, or a broadcast is refused and logged.
It used to terminate the process — every other connected socket with it —
because one caller passed a bad name, and while the framework filters
`flight:`-prefixed events arriving in an envelope, an application deriving a
name from client *payload* is an ordinary pattern that reached the assertion.

## Server usage

```swift
import FlightChannels

struct RoomChannel: Channel {
    let broadcaster: ChannelBroadcaster

    // The join is the authorization gate. Identity was established
    // during the HTTP upgrade, before the WebSocket existed.
    func join(_ topic: String, socket: Socket) async -> JoinResult {
        guard let principal = socket.principal else { return .reject(.unauthenticated) }
        guard topic == "room:\(principal.subject)" || principal.hasRole("admin")
        else { return .reject(.forbidden) }
        return .ok(initialState: ["history": []])
    }

    func handle(_ event: InboundEvent, socket: Socket) async -> HandleResult {
        switch event.event {
        case "new_msg":
            // Channels never fans out itself — PubSub does.
            await broadcaster.broadcast(topic: event.topic, event: "new_msg", payload: event.payload)
            return .reply(["sent": true])
        default:
            return .error(reason: "unknown_event")
        }
    }

    func leave(_ topic: String, socket: Socket) async { /* optional */ }
}

struct AppModule: FlightModule {
    static var dependencies: [any FlightModule.Type] { [FlightChannelsModule.self] }

    func configure(_ container: Container) throws {
        container.registerChannel("room:*") { c in
            RoomChannel(broadcaster: try c.resolve(ChannelBroadcaster.self))
        }
        container.registerChannelSocket("/socket") { context in
            // Runs during the upgrade request. Return a principal,
            // nil for anonymous, or throw HTTPError(.unauthorized).
            try await verify(context.request.queryParam("token"))
        }
    }
}
```

Topic patterns are exact (`"lobby"`), prefix-wildcard (`"room:*"`), or
catch-all (`"*"`); the most specific match wins, and duplicate or malformed
patterns fail bootstrap, not a join. Joining creates one `Channel` instance
per (socket, topic) — instances may hold per-membership state.

Anything can broadcast — a channel handler, a background job, another node:

```swift
let broadcaster = try container.resolve(ChannelBroadcaster.self)
await broadcaster.broadcast(topic: "room:42", event: "system", payload: ["msg": "hi"])
await broadcaster.broadcast(topic: "room:42", event: "new_msg", payload: p, excluding: senderSocket)
```

## Swift client usage

```swift
import FlightChannelsClient

let client = ChannelClient(url: url, transport: myTransport) // transport seam, see below
try await client.connect()

let room = client.channel("room:42")
let initialState = try await room.join()               // the join gate answers
let reply = try await room.push("new_msg", payload: ["body": "hi"])  // awaits flight:reply
try await room.send("typing", payload: ["on": true])   // fire-and-forget, ref: null

for await message in await room.messages() {            // server pushes, as a stream
    if message.isRejoin { /* fresh state after auto-reconnect */ }
}
```

Reconnection is client-driven: on a drop the client re-dials with
`ReconnectPolicy` backoff and rejoins every joined topic; the fresh initial
state arrives on `messages()` as a `flight:join` message. In-flight pushes
fail fast with `.disconnected`. Heartbeats run automatically; an unanswered
heartbeat is treated as a dead connection.

`ChannelClientTransport` is the one seam: implement `connect(to:)` over any
WebSocket (the E2E suite shows a hummingbird `WSClient` adapter in ~60
lines; `FlightChannelsTesting` ships the in-memory one).

## Wire protocol — the contract all three artifacts version together

One envelope, both directions, JSON text frames in v1:

```json
{ "ref": "7", "topic": "room:42", "event": "new_msg", "payload": { } }
```

- `ref` correlates request → reply; server pushes carry `ref: null`.
  All four keys are always present.
- Reserved events: `flight:join`, `flight:leave`, `flight:reply`,
  `flight:error` (payload `{"reason": "…"}`), `flight:heartbeat`,
  `flight:close`. Everything else routes to the channel's `handle`.
- Socket-level control events travel on the reserved topic `"flight"`,
  which can never be joined.
- Correlated success is `flight:reply` with the ref; correlated failure
  (join rejected, handler error) is `flight:error` with the ref.
- Close codes beyond RFC 6455's set: `4000` heartbeat timeout, `4400`
  protocol violation (undecodable envelope); binary frames close with
  `1003` (the binary codec is a later, negotiated addition).
- Server-produced error reasons: `unauthenticated`, `forbidden`,
  `unmatched_topic`, `already_joined`, `not_joined`, `reserved_topic`,
  `handler_error`, `invalid_event`.

Semantics inherited from PubSub: at-most-once, no durability, no
replay. Per-socket inbound processing is serial (one envelope fully handled
before the next), and all outbound writes funnel through one per-socket
queue — a slow client never blocks a handler, and frames never interleave.

## Configuration

| Key | Default | Meaning |
|---|---|---|
| `flight.channels.heartbeat-timeout-seconds` | `60` | A socket silent this long is closed (any frame counts as liveness) |
| `flight.channels.heartbeat-check-interval-seconds` | timeout ÷ 4 | Watchdog cadence |
| `flight.channels.outbound-buffer-size` | `256` | Queued frames per socket before the oldest are dropped |
| `flight.channels.write-timeout-seconds` | `30` | One outbound frame taking longer than this closes the socket (`0` disables) |

The write timeout is the bound the watchdog cannot supply. The watchdog counts
*inbound* frames as liveness, so a client that keeps heartbeating while never
reading looks perfectly alive to it — and the writer sits in `send` against a
TCP window that never opens, forever. Memory stays bounded by the outbound
queue; what accumulates is a task and a connection per such client, which is
slow resource exhaustion rather than fast.

Client side: `ChannelClientConfiguration(heartbeatInterval: .seconds(25),
pushTimeout: .seconds(10), reconnect: .exponentialBackoff())`.

## Testing support

```swift
let container = try TestContainer.build { AppModule() }
let transport = InMemoryChannelTransport(testClient: try TestClient(container: container))
let client = ChannelClient(url: URL(string: "flight-test:///socket")!, transport: transport)
```

Full stack — routing, upgrade, session, PubSub — in process. Every
`connect` dispatches a fresh upgrade, so reconnect/rejoin paths are
exercised for real. `ChannelWireClient` drives raw envelopes for
wire-level assertions. Multi-node behavior is testable with
`FlightPubSubTesting.InMemoryCluster` (see `MultiNodeTests`).

## Design notes

1. **`ChannelPrincipal` is a seam, not Security's `Principal`**. Channels'
   requirement is only "the join gate can read who this is", so it owns a
   two-member protocol (`subject`, `hasRole(_:)`) plus `BasicPrincipal` for
   simple cases, and takes no dependency on Security at all — a WebSocket
   layer should work with any notion of identity, or none.

   `FlightSecurityCore` ships, and the two meet in application code:

   ```swift
   extension Principal: @retroactive ChannelPrincipal {}
   ```

   The conformance is empty because `Principal` already has both members.
   Its validator then feeds `registerChannelSocket`'s `authenticate`
   closure, with no Channels change — which is what the seam was for. Same
   "seam, not engine" posture the package takes with transports and PubSub
   adapters.
2. **`JoinResult`/`HandleResult` are structs with static constructors**,
   not enums — the design's call sites (`.ok`, `.ok(initialState:)`) need
   an overload an enum case can't provide; the shapes are otherwise the
   doc's.
3. **`flight:error` answers correlated failures** (join rejected, handler
   error) carrying the originating `ref`; `flight:reply` is success-only.
   The doc lists both events without pinning the correlation rule; this
   split keeps "one obvious meaning per event" and lets clients reject the
   awaited promise/continuation directly.
4. **`HandleResult.none` on a ref-carrying message sends nothing** — the
   client's push times out. Mirrors Phoenix's `:noreply`: whether an event
   replies is the channel's contract with its client, not something the
   transport papers over. Clients ship `send`/fire-and-forget for
   known-no-reply events.
5. **The exit path never waits on the transport after a server-initiated
   close.** A half-open peer (the case heartbeats exist for) never
   completes the close handshake, so the frame loop is unblocked by task
   cancellation, not by the frame stream ending. Watchdog teardown
   finishes the outbound queue; the writer drains what was already queued
   (a graceful `flight:close` ack is flushed before the close frame), then
   everything is joined deterministically.
6. **`ChannelBroadcaster.broadcast(…, excluding:)`** — not in the doc, but
   the "tell everyone else" shape every chat-like handler wants. Carried
   as PubSub metadata (`flight.channels.origin`), filtered at the
   subscription pump, so it works across nodes unchanged.
7. **Rejoin state delivery** (client): after auto-reconnect, the fresh
   initial state is announced on the channel's message stream as a
   `flight:join` message (`ChannelMessage.isRejoin`). The original
   `join()` caller got its state as the return value; the stream is the
   only live surface after a silent reconnect.
