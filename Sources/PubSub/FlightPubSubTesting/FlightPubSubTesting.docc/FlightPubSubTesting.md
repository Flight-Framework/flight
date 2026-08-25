# ``FlightPubSubTesting``

Several nodes in one process, so clustered behaviour is testable at desk
speed.

## Overview

``InMemoryCluster`` hands out ``InMemoryClusterAdapter`` values that all
deliver to each other. Give one to each of several `ClusteredPubSub`
instances and you have a multi-node deployment inside a single test, with no
containers and no network:

```swift
let cluster = InMemoryCluster()
let a = ClusteredPubSub(local: LocalPubSub(), adapter: cluster.makeAdapter())
let b = ClusteredPubSub(local: LocalPubSub(), adapter: cluster.makeAdapter())

try await a.publish(Message(topic: "orders", payload: data))
// b's subscribers receive it
```

`echoesToOrigin:` controls whether a publisher sees its own message come back
through the adapter — real adapters differ on this, and code that assumes one
behaviour breaks against the other. Testing both is the point of it being a
parameter.

## Testing what happens when the cluster misbehaves

``RecordingAdapter`` is the adversarial one. It records what was broadcast,
injects messages that no local publish produced, and — via
`setBroadcastError` — fails on demand.

That last one matters more than it looks. A `publish` whose remote hop fails
must still have delivered locally, and the local subscribers must not find
out about the remote failure. That behaviour is easy to get wrong, invisible
in production until a cluster partition, and trivial to assert here.

## Topics

### A cluster in one process

- ``InMemoryCluster``
- ``InMemoryClusterAdapter``

### Making the cluster misbehave

- ``RecordingAdapter``
