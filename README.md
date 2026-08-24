# Flight

A modular server-side framework for Swift. Dependency injection and
application lifecycle at the bottom, HTTP and WebSockets above it, and
real-time layers — PubSub, Channels, Presence — on top of those.

One package, many products. Take only what you use: a JSON API needs
`FlightWeb` and `FlightTransport`; a collaborative app adds `FlightChannels`
and `FlightPresence`; a service behind an existing identity provider adds
`FlightSecurityCore`.

## Products

| Product | What it is |
| --- | --- |
| `FlightCore` | Container, modules, registration, application lifecycle. Everything else builds on this. |
| `FlightConfig` / `FlightConfigCore` | Layered configuration over swift-configuration; `FlightConfigCore` is the dependency-free parser and vocabulary. |
| `FlightWeb` | Routing, middleware, `RequestContext`, `Response`, WebSocket and SSE, and the `ServerTransport` seam. |
| `FlightTransport` | The default transport, wrapping HummingbirdCore. A peer of any third-party transport — the only target that knows what the transport wraps. |
| `FlightPubSub` | Topic-based publish/subscribe with a `DistributedPubSubAdapter` seam for cluster fan-out. |
| `FlightChannels` | Per-connection lifecycle over PubSub and Web: join, leave, push, broadcast. |
| `FlightPresence` | CRDT-merged "who is here", correct across a cluster without central coordination. |
| `FlightActuator` | Health, info, and metrics endpoints, off by default outside development. |
| `FlightSecurityCore` | A resource server: validates tokens your identity provider issued. Bring your own auth. |
| `*Testing` | Test support for Web, PubSub, and Channels — in-memory transports, mock contexts, cluster harnesses. |

Per-product documentation lives in [Docs/](Docs/).

## Getting started

```swift
.package(url: "https://github.com/Swift-Flight/flight.git", from: "0.1.0")
```

```swift
.target(name: "App", dependencies: [
    .product(name: "FlightWeb", package: "flight"),
    .product(name: "FlightTransport", package: "flight"),
])
```

## Traits

Merging eight packages into one would otherwise hand every consumer the union
of their dependencies. Two traits prevent that — SwiftPM resolves only what an
enabled trait reaches.

| Trait | Default | Brings |
| --- | --- | --- |
| `Web` | **on** | HTTP, WebSockets, SSE, Channels, Presence, actuator — Hummingbird, NIO, the TLS stack |
| `Security` | off | `FlightSecurityCore` — JWTKit, AsyncHTTPClient. Enables `Web`. |

`Web` is on by default, so an application that serves HTTP needs no trait
ceremony at all. Authentication is opt-in:

```swift
.package(url: "https://github.com/Swift-Flight/flight.git",
         from: "0.1.0", traits: ["default", "Security"])
```

And a consumer that wants only the container and lifecycle opts out, which
drops it from 28 resolved packages to 7:

```swift
.package(url: "https://github.com/Swift-Flight/flight.git",
         from: "0.1.0", traits: [])
```

### Building this repository

A root build compiles every target regardless of traits, so it needs them all
enabled:

```
swift build --enable-all-traits
swift test  --enable-all-traits
```

A plain `swift build` here fails by design — the trait-gated targets find
their dependencies pruned. `CI/check-lean-consumer.sh` verifies the lean
configuration the only way that proves anything: by building a real consumer
and asserting no gated dependency reached it.

## Backends

Database and cache drivers deliberately live outside this package, in
`flight-data`, so that nothing here forces a Postgres or Valkey dependency
onto an application that does not use one.

## Requirements

Swift 6.2+, macOS 15+ or Linux. Strict concurrency throughout — every target
builds in Swift 6 language mode.

## Testing

`swift test --enable-all-traits` — 685 tests across 14 targets, no external
services required.
