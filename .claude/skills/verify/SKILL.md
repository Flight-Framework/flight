---
name: verify
description: Build, launch, and drive flight-actuator end-to-end over a real HTTP socket.
---

# Verifying flight-actuator

Library package — its surface is `GET /actuator` on a bootstrapped Flight
app. Drive it with a scratch executable on the full stack (FlightTransport
/ NIO), not just `swift test`.

## Scratch app recipe

Create a package with an executable target depending on products
`FlightActuator` (this package), `FlightWeb` + `FlightTransport`
(`../flight-web`), and `FlightCore` (`../../Core/flight-core`); platforms
`.macOS(.v15)`, tools 6.1. Main:

```swift
try await bootstrap(
    configuration: try Configuration.load(),
    modules: [FlightWebModule<FlightTransport>.self, ActuatorModule.self]
)
```

Give it a `flight.yaml` with `server: {host: 127.0.0.1, port: 8199}` in the
package root (`Configuration.load()` reads it from cwd).

## Drive

```bash
FLIGHT_ENV=dev ./.build/debug/<App> &          # SSR dashboard
curl -i http://127.0.0.1:8199/actuator          # 200 text/html
FLIGHT_ACTUATOR_FORMAT=json FLIGHT_ENV=staging ./.build/debug/<App> &
curl -i http://127.0.0.1:8199/actuator          # 200 application/json
FLIGHT_ENV=prod ./.build/debug/<App> &
curl -i http://127.0.0.1:8199/actuator          # 404 — route not registered
FLIGHT_ACTUATOR_FORMAT=xml ./.build/debug/<App> # loud bootstrap failure
```

## Gotchas

- `pkill -f <AppName>` kills your own shell (the pattern matches the bash
  command line). Use `pkill -x <AppName>`.
- A malformed `actuator.format` terminates via Swift's "Error raised at top
  level" fatalError (SIGILL, exit 132) — that's the platform's throwing-
  `@main` behavior, not a bug; the message names key/value/type.
- Sibling SwiftPM builds share this `.build`; a concurrent `swift build`
  in another session makes SPM wait on the lock.
