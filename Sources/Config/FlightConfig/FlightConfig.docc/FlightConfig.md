# ``FlightConfig``

Layered, environment-aware configuration that fails at startup, not at
request time.

## Overview

Configuration goes wrong in one of two ways. Either a value is missing, or a
value is present and means something you did not intend. The second is worse,
because it does not announce itself — a service comes up, serves traffic, and
resolves a production key from a development file.

This library is built around making both loud, and making them loud at
startup:

```swift
let configuration = try Configuration.load()

let port: Int = try configuration.get("server.port")
let poolSize = configuration.get("datasource.pool_size", default: 10)
```

Three layers resolve in precedence order — environment variables, then
`flight-{env}.yaml`, then `flight.yaml` — and a key found in a higher layer
wins outright. What makes that safe is the rule underneath it: a layer that
holds a key but cannot answer the request **stops the walk** rather than
letting resolution continue downward. Falling through would answer a
production key from a development layer without saying so.

## Two modules

``FlightConfig`` is the runtime: the ``Configuration`` facade, the loader,
and the swift-configuration bridge. Applications import this.

`FlightConfigCore` is the grammar and vocabulary — the YAML parser, `${VAR}`
substitution, `ConfigDecodable`, the error types, `FlightEnvironment`. It
has no dependencies, deliberately, because build tools link it to check
configuration keys at compile time and a build tool's dependencies are paid
for by every consumer's build.

Importing ``FlightConfig`` re-exports the core, so one import gives you
everything.

## Topics

### Essentials

- ``Configuration``

### Errors


### Providers

- ``FlightYAMLProvider``
- ``FlightYAMLSnapshot``

### Guides

- <doc:LayeringAndPrecedence>
- <doc:TheYAMLSubset>
- <doc:SecretsAndSubstitution>
