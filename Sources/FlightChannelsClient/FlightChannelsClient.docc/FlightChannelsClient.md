# ``FlightChannelsClient``

The Swift channel client: connect, join topics, and survive the connection
dropping.

## Overview

``ChannelClient`` is the counterpart to `FlightChannels` for a Swift caller —
another service, an integration test, an iOS app:

```swift
let client = ChannelClient(url: url, transport: transport)
let room = try await client.join("room:42")

for await message in room.messages {
    handle(message)
}
```

``ChannelHandle`` is one joined topic. ``ChannelMessage`` is what arrives on
it.

## Reconnection is the feature

A channel client that gives up when the socket drops has solved the easy
half. ``ReconnectPolicy`` governs backoff, and the client replays its joins
after reconnecting — so a caller holding a ``ChannelHandle`` keeps receiving
messages across an outage without writing any recovery code.

``ConnectionState`` is observable for the cases where the application does
want to know: showing a "reconnecting" banner, pausing optimistic writes.

## The transport is a seam

``ChannelClientTransport`` is what actually carries bytes.
`FlightChannelsTesting`'s in-memory transport conforms to it, which is how
end-to-end channel tests run with no socket, no port, and no timing
assumptions.

## Topics

### Connecting

- ``ChannelClient``
- ``ChannelClientConfiguration``
- ``ConnectionState``
- ``ReconnectPolicy``

### Topics and messages

- ``ChannelHandle``
- ``ChannelMessage``

### Transport

- ``ChannelClientTransport``
- ``ClientTransportConnection``

### Failure

- ``ChannelClientError``
