# ``FlightChannelsProtocol``

The channel wire format, shared by the server and every client.

## Overview

This module exists so that a change to the wire format breaks a build rather
than a production socket. `FlightChannels` (server) and
`FlightChannelsClient` (Swift client) both depend on it, and
`flight-channels-js` implements the same shapes by hand — so this is the
document the JavaScript is written against.

``Envelope`` is the frame: a topic, an event name, a payload, and an optional
reference for matching a reply to a request.

```
{"topic": "room:42", "event": "new_msg", "payload": {"body": "hi"}, "ref": "7"}
```

``ReservedEvent`` names the frames the protocol itself owns — join, leave,
reply, error, heartbeat — so an application event can never collide with one
by accident.

## Payloads are JSONValue, deliberately

``JSONValue`` is an enum rather than `Any` or a generic. A channel payload
crosses a network boundary to a language with no Swift types in it, so the
set of things it can be is exactly JSON's set of things, and making that a
closed enum means the compiler checks it.

## Errors and closes are named

``ChannelErrorReason`` and ``ChannelCloseCode`` are shared vocabulary rather
than free-form strings: a client can branch on `unauthenticated` versus
`forbidden` without string-matching a message that might be reworded.

``EnvelopeDecodingError`` is what a malformed frame produces — reported
rather than silently dropped, because a client sending frames nobody can
parse should find out.

## Topics

### Frames

- ``Envelope``
- ``ReservedEvent``
- ``JSONValue``

### Failure

- ``ChannelErrorReason``
- ``ChannelCloseCode``
- ``EnvelopeDecodingError``

### Constants

- ``ChannelProtocol``
