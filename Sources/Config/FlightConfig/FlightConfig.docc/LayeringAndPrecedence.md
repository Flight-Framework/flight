# Layering and precedence

How three sources resolve into one value, and what happens when they
disagree.

## Overview

Configuration resolves from three layers, highest precedence first:

| Layer | Source | What belongs here |
|---|---|---|
| Environment variables | `FLIGHT_SERVER_PORT` | Deployment overrides, secrets |
| Environment overlay | `flight-{env}.yaml` | What differs per environment |
| Base | `flight.yaml` | Defaults that hold everywhere |

`flight.yaml` must exist — it is the file that defines what keys your
application has. The overlay is optional.

```yaml
# flight.yaml — the defaults
server:
  port: 8080
datasource:
  url: postgres://localhost/app_dev
  pool_size: 5
```

```yaml
# flight-prod.yaml — only what changes
datasource:
  url: "${DATABASE_URL}"
  pool_size: 50
```

In production, `server.port` resolves to `8080` from the base file, while
`datasource.pool_size` resolves to `50` from the overlay. Nothing needs
restating in the overlay just to keep it.

## Environment variables

A dotted key becomes an upper-snake-case variable with a `FLIGHT_` prefix:

```
server.port           →  FLIGHT_SERVER_PORT
datasource.pool_size  →  FLIGHT_DATASOURCE_POOL_SIZE
```

Setting one overrides both files. This is how a deployment platform injects
values without a configuration change, and it is where secrets belong.

## The rule that makes layering safe

A key found in a higher layer wins. A key *absent* from a higher layer falls
through. Those two are obvious. The third case is the one that matters:

**A layer that holds the key but cannot answer the request stops the walk.**

```yaml
# flight-prod.yaml
cluster:
  hosts:
    - alpha
    - beta
```

```swift
try configuration.get("cluster.hosts", as: String.self)
// throws ConfigError.unrepresentableValue —
// "present in flight-prod.yaml as an array of strings"
```

It would be easy to treat "I cannot render this as a string" as "not here"
and continue to the next layer. That is precisely what must not happen: the
next layer is the development file, and answering from it would silently give
a production deployment a development value. So resolution stops and reports
what it found, where it found it.

Read those values through ``Configuration/reader`` and ask for the array type
directly:

```swift
configuration.reader.stringArray(forKey: "cluster.hosts")   // ["alpha", "beta"]
```

## Environments

`FlightEnvironment.current` reads `FLIGHT_ENV`. Unset means
`FlightEnvironment.dev`.

Four environments ship with the package, but the type is extensible:

```swift
extension FlightEnvironment {
    static let qa = FlightEnvironment("qa")
}
```

A value that is not one of the built-ins resolves to itself. `FLIGHT_ENV=qa`
looks for `flight-qa.yaml` — it does not quietly become `dev`, because
loading development configuration under a production-shaped name is the
failure mode this library is organized around preventing.

## Custom providers

Anything conforming to swift-configuration's `ConfigProvider` layers in at
any precedence:

```swift
let configuration = try Configuration.load(
    additionalProviders: [remoteSecretsProvider]
)
```

This is the seam for remote configuration, secret managers, and anything else
this package deliberately does not implement.

## Inspecting a resolved stack

When a key resolved to something surprising, the question is *which layer
said so*:

```swift
print(configuration)
// Configuration (environment: prod), 3 providers, highest precedence first:
//   1. EnvironmentVariables[12 values]
//   2. FlightYAML[flight-prod.yaml, 4 keys]
//   3. FlightYAML[flight.yaml, 18 keys]
```

``Configuration/description`` names the layers without printing values, so it
is safe to log unconditionally. ``Configuration/debugDescription`` adds the
values, with secrets redacted — see <doc:SecretsAndSubstitution>.
