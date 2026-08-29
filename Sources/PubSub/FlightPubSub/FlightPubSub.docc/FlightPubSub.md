# ``FlightPubSub``

Publish/subscribe within a process, and across a cluster when an adapter is
configured.

## Overview

``PubSub`` is the whole interface: publish a ``Message`` to a topic,
subscribe to one. Everything else is which implementation is registered.

```swift
@Autowired var pubsub: any PubSub

await pubsub.publish(Message(topic: "orders", payload: data))

for await message in pubsub.subscribe("orders") {
    handle(message)
}
```

Neither call throws, and `subscribe` is synchronous — deliberately, so that
a subscription is in place the moment the call returns and cannot miss a
publish that races it.

``LocalPubSub`` delivers in-process and is what a single node uses.
``ClusteredPubSub`` wraps it with a ``DistributedPubSubAdapter`` so a publish
on one node reaches subscribers on every node.

**No adapter ships yet.** ``DistributedPubSubAdapter`` is a seam, not a
feature with an implementation behind it: two methods — broadcast one
message, receive a stream of others' — narrow enough to write against Valkey,
NATS or Redis in an afternoon, but until you do, every deployment is
effectively single-node. `FlightPubSubTesting`'s `InMemoryCluster` is the
only conforming implementation today, and it exists to test the clustered
paths rather than to run them.

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
