# ``FlightChannelsTesting``

Channel tests with no socket, no port, and no timing assumptions.

## Overview

A channel test that binds a real WebSocket is testing the operating system's
scheduler as much as your join logic, and it fails on a loaded CI machine for
reasons that have nothing to do with the code. Both types here remove the
socket instead.

``InMemoryChannelTransport`` conforms to `FlightChannelsClient`'s
`ChannelClientTransport`, so a real `ChannelClient` — with its real
reconnection and join replay — runs against a real server built from a
`TestClient`:

```swift
let transport = InMemoryChannelTransport(testClient: client)
let channels = ChannelClient(url: url, transport: transport)
let room = try await channels.join("room:42")
```

That is a genuine end-to-end test of both halves. Nothing is stubbed except
the bytes.

## Testing the wire itself

``ChannelWireClient`` is the lower level: it sends and receives `Envelope`
values directly over an `InMemoryWebSocket`, with no client-side state
machine in between.

Reach for it when the thing under test *is* the protocol — a malformed
frame's error reply, a join to a topic no channel claims, the exact close
code on an unauthenticated join. Those are assertions about frames, and
asserting them through a client that helpfully retries and reconnects tests
the wrong layer.

## Topics

### End-to-end, through the real client

- ``InMemoryChannelTransport``

### Frame by frame

- ``ChannelWireClient``
