# ``FlightPubSub``

Publish/subscribe within a process, and across a cluster when an adapter is
configured.

## Overview

``PubSub`` is the whole interface: publish a ``Message`` to a topic,
subscribe to one. Everything else is which implementation is registered.

```swift
@Autowired var pubsub: any PubSub

try await pubsub.publish(Message(topic: "orders", payload: data))

for await message in try await pubsub.subscribe("orders") {
    handle(message)
}
```

``LocalPubSub`` delivers in-process and is what a single node uses.
``ClusteredPubSub`` wraps it with a ``DistributedPubSubAdapter`` so a publish
on one node reaches subscribers on every node — the Valkey adapter in
`flight-data` is one, and the seam is narrow enough to write another.

## Local first, clustered by configuration

A single-node application registers ``LocalPubSub`` and never learns that
clustering exists. Adding an adapter does not change a call site: the same
`publish` reaches the same subscribers plus the ones on other nodes.

That is why `FlightChannels` can build broadcast on top of this and stay
indifferent to deployment shape.

## Topics

### The interface

- ``PubSub``
- ``Message``

### Implementations

- ``LocalPubSub``
- ``ClusteredPubSub``
- ``DistributedPubSubAdapter``

### Hosting

- ``FlightPubSubModule``
- ``PubSubRelayService``
- ``PubSubWiringError``
