# ``FlightChannels``

Named topics over one WebSocket: join, broadcast, and per-topic
authorization.

## Overview

A raw WebSocket gives you a byte stream and a lot of homework. Channels give
you the thing applications actually want — many logical conversations
multiplexed over one connection, each with its own authorization decision and
its own broadcast fan-out:

```swift
struct RoomChannel: Channel {
    let broadcaster: ChannelBroadcaster

    // The join is the authorization gate. Identity was established during
    // the HTTP upgrade, before the WebSocket existed.
    func join(_ topic: String, socket: Socket) async -> JoinResult {
        guard let principal = socket.principal else { return .reject(.unauthenticated) }
        guard topic == "room:\(principal.subject)" || principal.hasRole("admin")
        else { return .reject(.forbidden) }
        return .ok(initialState: ["history": []])
    }

    func handle(_ event: InboundEvent, socket: Socket) async -> HandleResult {
        switch event.event {
        case "new_msg":
            await broadcaster.broadcast(topic: event.topic, event: "new_msg", payload: event.payload)
            return .reply(["sent": true])
        default:
            return .error(reason: "unknown_event")
        }
    }
}
```

A ``Socket`` is one client connection; it may be joined to many topics. A
``TopicPattern`` decides which channel type owns a topic name, so
`room:lobby` and `room:42` route to the same ``Channel`` implementation with
different topic strings. Joining creates one channel instance per
(socket, topic) pair, so per-membership state can live in stored properties.

## Authorization happens at join

``Channel/join(_:socket:)`` is the only place a client's access to a topic is
decided, and it runs before any message reaches ``Channel/handle(_:socket:)``.
That is deliberate: authorizing per message is where per-message bugs live.

Note that neither method throws. A channel answers with ``JoinResult`` or
``HandleResult`` — `.reject(.forbidden)`, `.error(reason:)` — because every
outcome has to become a frame the client can act on, and an escaping error
would only have to be caught and converted at the boundary anyway.

``ChannelPrincipal`` is the identity a socket carries, established during the
HTTP upgrade. Conform your own principal type to it — `FlightSecurityCore`'s
`Principal` already does — or use ``BasicPrincipal`` when the socket only
needs a subject and roles.

## Broadcasting

``ChannelBroadcaster`` sends to every socket joined to a topic, from anywhere
in the application: a controller, a background job, a scheduled task. It does
not require a socket of its own, and a channel never fans out by hand.

In a cluster the broadcast goes through `FlightPubSub`, so a node holds only
the sockets connected to *it* and the fan-out crosses nodes without any
channel code knowing which deployment shape it is in.

## The browser side

`flight-channels-js` is the client: it speaks the same frame format, handles
reconnection with backoff, and replays joins. The wire format lives in
`FlightChannelsProtocol`, shared by both ends, so a frame change breaks the
build rather than a production socket.

## Topics

### Defining a channel

- ``Channel``
- ``TopicPattern``
- ``JoinResult``
- ``JoinRejection``
- ``HandleResult``
- ``InboundEvent``

### Connections and identity

- ``Socket``
- ``ChannelPrincipal``
- ``BasicPrincipal``

### Broadcasting

- ``ChannelBroadcaster``
- ``BroadcastFrame``

### Hosting

- ``FlightChannelsModule``
- ``ChannelsConfiguration``
- ``ChannelRegistration``
- ``ChannelRouter``
- ``ChannelSocketHandler``
- ``ChannelsError``
