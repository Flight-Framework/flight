# ``FlightPresenceClient``

Presence for a Swift channel client: subscribe to a topic, get who is there.

## Overview

``ChannelPresence`` sits on top of a `ChannelHandle` and turns the presence
frames arriving on it into a maintained roster:

```swift
let room = try await client.join("room:42")
let presence = ChannelPresence(channel: room)
await presence.start()

for await change in presence.changes() {
    render(change)
}
```

``ChannelPresence/start()`` begins consuming; ``ChannelPresence/stop()`` ends
it. The stream yields changes rather than snapshots, because a UI updating a
list wants to know what moved.

## It applies diffs, it does not poll

The server sends the initial state once and joins and leaves after that. This
type applies them in order and keeps the result — which is why it is an actor
and why `start()` exists at all: the roster is state, and it has to be
consistent while it is read.

The same design as the browser client, for the same reason: re-sending the
whole roster on every change is what makes presence expensive in a busy
topic.

## Topics

### Tracking a topic

- ``ChannelPresence``
