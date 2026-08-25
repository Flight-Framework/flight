# ``FlightTransport``

The shipped HTTP server transport: HummingbirdCore behind
`FlightWeb`'s `ServerTransport` seam.

## Overview

Nothing in `FlightWeb`'s API mentions this module. A controller, a route, a
middleware and a `Request` are all expressible without knowing which server
is listening — which is what makes `FlightWebTesting`'s in-memory transport
possible, and what would make a different server a configuration change
rather than a rewrite.

``FlightTransport`` is the production answer to that seam:

```swift
try await Flight.bootstrap(
    configuration: try Configuration.load(),
    modules: [FlightWebModule<FlightTransport>.self, AppModule.self]
)
```

## Configuration

``FlightTransportConfiguration`` covers the host, the port, and TLS. TLS is
configured with a certificate and key path; a malformed pair fails at startup
with ``TLSConfigurationError`` rather than at the first handshake, which is
the point of validating it during bootstrap.

## Topics

### The transport

- ``FlightTransport``
- ``FlightTransportConfiguration``
- ``TLSConfigurationError``
