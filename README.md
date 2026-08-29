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
| `FlightActuator` | Health probes always on; a topology dashboard only where a development environment is declared. |
| `FlightSecurityCore` | A resource server: validates tokens your identity provider issued. Bring your own auth. |
| `FlightScheduler` / `FlightCronCore` | Cron and interval jobs as annotated methods, with the schedule checked at build time. `FlightCronCore` is the dependency-free engine the macro validates with. |
| `*Testing` | Test support for Web, PubSub, Channels, and the Scheduler — in-memory transports, mock contexts, cluster harnesses, a clock that does not sleep. |

Per-product documentation lives in [Docs/](Docs/), and
[Docs/testing.md](Docs/testing.md) covers how to test an application built
on it.

## Getting started

```swift
.package(url: "https://github.com/Swift-Flight/flight.git", from: "0.10.0")
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

| Trait | Brings |
| --- | --- |
| `Web` | HTTP, WebSockets, SSE, Channels, Presence, actuator — Hummingbird, NIO, the TLS stack |
| `Security` | `FlightSecurityCore` — JWTKit, AsyncHTTPClient. Implies `Web`. |

Both are opt-in. Name what you want:

```swift
// An HTTP service.
.package(url: "https://github.com/Swift-Flight/flight.git",
         from: "0.10.0", traits: ["Web"])

// …with authentication.
.package(url: "https://github.com/Swift-Flight/flight.git",
         from: "0.10.0", traits: ["Security"])

// Just the container and lifecycle — 7 resolved packages instead of 29.
.package(url: "https://github.com/Swift-Flight/flight.git", from: "0.10.0")
```

**Swift 6.3 or later is required.** Through 6.2.x, SwiftPM did not resolve the
gated dependencies of a non-default trait enabled on a *versioned* dependency,
failing with *"exhausted attempts to resolve the dependencies graph"*
([#9286](https://github.com/swiftlang/swift-package-manager/issues/9286), fixed
by [#9269](https://github.com/swiftlang/swift-package-manager/pull/9269)).
Path dependencies always worked, so it appeared only once this package was
tagged. The manifest declares tools version 6.3 so an older toolchain says so
plainly instead of failing obscurely.

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

Swift 6.3+ (see Traits above for why), Linux or macOS 15+. Strict concurrency
throughout — every target builds in Swift 6 language mode.

> **macOS is not currently buildable**, for a reason upstream of this package:
> `apple/swift-configuration` 1.2.0 — its latest release — does not compile on
> Darwin, because `FileProvider.swift` reaches for `Data.bytes`, which exists
> on the Linux Foundation it was written against and not on the Darwin one.
> Nothing here can fix it, and pinning an unreleased `main` is worse than
> saying so. The macOS CI job runs and reports honestly rather than gating
> merges. Recorded in [GAPS.md](GAPS.md) §1.

## Testing

`swift test --enable-all-traits` — 1,000+ tests across 16 targets, no external
services required.

## License

MIT. See [LICENSE](LICENSE).
