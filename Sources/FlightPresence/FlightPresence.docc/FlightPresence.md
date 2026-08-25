# ``FlightPresence``

Who is here, on which topic, across every node — and an honest account of
what happens when a node dies.

## Overview

Presence looks trivial until it is distributed. One node tracking its own
sockets is a dictionary. Many nodes agreeing on a shared answer, while
sockets come and go and nodes occasionally stop answering, is the actual
problem:

```swift
@Autowired var presence: any Presence

await presence.track(topic: "room:42", key: user.id, payload: ["name": user.name], socket: socket)
let here = await presence.list(topic: "room:42")     // [PresenceEntry]
```

State is a CRDT — ``PresenceCRDTState`` over ``PresenceDot`` and
``DotContext`` — so two nodes that gossip in either order converge on the
same answer, and a message arriving twice changes nothing. That is what
makes the distributed case tractable at all.

## The failure-detection mode decides what you actually get

This is the part worth reading before deploying. ``PresenceMode`` is derived
from what is registered, and it is logged loudly at startup because the three
modes have genuinely different guarantees:

- ``PresenceMode/singleNode`` — no distributed adapter. Node failure is not a
  distributed concern because there is only one. Exact.
- ``PresenceMode/membership`` — a ``PresenceMembershipMonitor`` is
  registered. A dead node's entries are removed promptly and correctly,
  because something is actually detecting the death. **The intended
  multi-node mode.**
- ``PresenceMode/heartbeatExpiry`` — a fan-out-only adapter (Valkey-style)
  and no membership signal. Removal is delayed by up to the expiry timeout,
  and a slow node may flap in and out. Documented, degraded, and chosen for
  you only when nothing better is available.

A deployment that thinks it is in `membership` mode and is actually in
`heartbeatExpiry` will show departed users for as long as the timeout — which
is why the mode is a startup log line rather than an implementation detail.

## Tuning is a trade, not a default

``PresenceConfiguration`` carries the heartbeat interval and the down-after
timeout. ``PresenceConfigurationError`` refuses a configuration where
`downAfter` is not comfortably above `heartbeat` — that combination declares
healthy nodes dead, and the failure looks like random users disappearing.

## The browser side

`PresenceEntry` and `PresenceSync` are the wire types, shared with the
client through `FlightPresenceProtocol` so a change breaks the build rather
than a production socket. `FlightPresenceClient`'s `ChannelPresence` applies
diffs on top of a `ChannelClient` subscription.

## What is still open

The gossip **trust model**. Presence assumes cooperating nodes: a malicious
or buggy node gossiping bad state is not defended against, and there is no
protocol-version negotiation for a rolling upgrade. Both need a threat-model
decision before any code, and neither is a problem inside a trusted network
boundary — which is where this is currently supported.

## Topics

### The application surface

- ``Presence``
- ``PresenceTracker``
- ``PresenceRecord``

### Deployment mode

- ``PresenceMode``
- ``PresenceMembershipMonitor``
- ``PresenceMembershipEvent``

### Configuration

- ``PresenceConfiguration``
- ``PresenceConfigurationError``

### Convergence

- ``PresenceCRDTState``
- ``PresenceDot``
- ``DotContext``
- ``PresenceReplicaID``
- ``PresenceStateChanges``

### Gossip

- ``PresenceGossip``
- ``PresenceGossipMessage``

### Hosting

- ``FlightPresenceModule``
- ``PresenceService``
