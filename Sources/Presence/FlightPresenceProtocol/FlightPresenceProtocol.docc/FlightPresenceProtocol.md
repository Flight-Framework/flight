# ``FlightPresenceProtocol``

The presence wire format, shared by the server and every client.

## Overview

Like `FlightChannelsProtocol`, this module exists so a wire change breaks a
build rather than a production socket. `FlightPresence` (server),
`FlightPresenceClient` (Swift) and `flight-channels-js` (browser) all speak
these shapes.

``PresenceEntry`` is one present key with its metas — one user, potentially
joined from several tabs or devices, which is why ``PresenceMeta`` is a list
rather than a single value. Collapsing them would make "Ada closed one tab"
indistinguishable from "Ada left".

## State arrives as a diff

``PresenceSync`` carries the initial state; ``PresenceSyncChange`` carries
what changed after that. Sending the whole roster on every join and leave is
what makes presence expensive in a busy topic, so the protocol sends joins
and leaves and lets the client apply them.

``PresenceEvent`` names the frames, so an application event can never collide
with a presence one.

## Topics

### State

- ``PresenceEntry``
- ``PresenceMeta``

### Synchronization

- ``PresenceSync``
- ``PresenceSyncChange``
- ``PresenceEvent``

### Constants

- ``PresenceWire``
