# flight-config

Layered, environment-aware configuration for Swift servers, built on
[swift-configuration](https://github.com/apple/swift-configuration).

Base file, environment overlay, environment variables — resolved in that
precedence order, validated once at startup, and typed at the point of use.
When a key is missing or malformed, you find out during boot with a message
naming the key and the environment, not three services deep at request time.

```swift
let configuration = try Configuration.load()

let port: Int = try configuration.get("server.port")
let poolSize = configuration.get("datasource.pool_size", default: 10)
let certPath: String? = try configuration.getIfPresent("tls.certificate")
```

## Installation

```swift
dependencies: [
    .package(url: "https://github.com/Swift-Flight/flight-config", from: "0.1.0")
]
```

```swift
.target(name: "MyApp", dependencies: [
    .product(name: "FlightConfig", package: "flight-config")
])
```

Requires Swift 6.0+. Supports macOS 15+, iOS 18+, tvOS 18+, watchOS 11+,
visionOS 2+, and Linux.

## Layering

Three layers, highest precedence first:

| Layer | Source | Purpose |
|---|---|---|
| Environment variables | `FLIGHT_SERVER_PORT` | Deployment-time overrides and secrets |
| Environment overlay | `flight-{env}.yaml` | What differs in staging, production, test |
| Base | `flight.yaml` | Defaults that hold everywhere |

`flight.yaml` must exist. The overlay is optional — an environment that
changes nothing simply has no file.

```yaml
# flight.yaml
server:
  port: 8080
datasource:
  url: postgres://localhost/app_dev
  pool_size: 5
```

```yaml
# flight-prod.yaml
datasource:
  url: "${DATABASE_URL}"
  pool_size: 50
```

A key set in a higher layer wins outright. A key absent from a higher layer
falls through to the next one.

### Environment variables

A dotted key maps to an upper-snake-case variable with a `FLIGHT_` prefix:

```
server.port           →  FLIGHT_SERVER_PORT
datasource.pool_size  →  FLIGHT_DATASOURCE_POOL_SIZE
```

Setting one overrides both files, with no configuration change required.

## Environments

`FLIGHT_ENV` selects the overlay. Unset means `dev`.

```swift
FlightEnvironment.current()      // FLIGHT_ENV=staging → .staging
```

`dev`, `test`, `staging`, and `prod` ship with the package, but the type is
extensible — a deployment with its own environments adds them without waiting
on a release:

```swift
extension FlightEnvironment {
    static let qa = FlightEnvironment("qa")     // loads flight-qa.yaml
}
```

A value that is not one of the built-ins resolves to itself rather than
silently collapsing to `dev`. `FLIGHT_ENV=qa` looks for `flight-qa.yaml`; if
that file does not exist you get base-file values and a visibly absent
overlay, rather than development configuration running under a
production-shaped name.

## Reading values

Three accessors, each for a different kind of "missing":

```swift
// Required. Throws if absent or malformed.
let port: Int = try configuration.get("server.port")

// Has a sensible default. Returns it only when the key is ABSENT.
let poolSize = configuration.get("datasource.pool_size", default: 10)

// Genuinely optional — absence means the feature is off.
let certPath: String? = try configuration.getIfPresent("tls.certificate")
```

> **`get(_:default:)` traps on a malformed value.** It applies the default
> when the key is absent, never when it is present and corrupt — silently
> substituting a default there would hide exactly the failure this library
> exists to surface. The value can come from the environment, so a deployment
> typo (`FLIGHT_SERVER_PORT=eighty`) reaches this path and aborts the process
> at startup. If you need to survive a malformed value, use `getIfPresent` or
> `get(_:as:)` and handle the error.

## The YAML subset

Deliberately small: nested maps, sequences, scalars, comments, and `${VAR}`
substitution. Flow style (`[a, b]`, `{k: v}`), block scalars, anchors, and
aliases are rejected with a message naming the construct and what to use
instead.

The point is that a configuration file cannot be *subtly* wrong. Anything the
parser does not fully understand is a loud failure at load, not a value that
means something unexpected at runtime.

## Substitution and secrets

`${VAR}` pulls from the process environment, with an optional fallback:

```yaml
datasource:
  url: "${DATABASE_URL}"
  pool_size: ${DB_POOL_SIZE:-10}
```

An unresolved `${VAR}` with no fallback fails the whole load. That is
deliberate: the alternative is a production deployment quietly running on
base-layer development values.

**Substituted values are treated as secrets.** They came from the deployment
environment, which is where credentials live, so they render as `<REDACTED>`
in any diagnostic dump:

```swift
String(reflecting: provider)
// FlightYAML[flight.yaml, 2 keys: db.host=localhost, db.password=<REDACTED>]
```

A literal written into the file is printed as-is — it is already disclosed by
the file it lives in.

## Errors

Every failure names the key, and load failures name the file, line, and
column:

```
Configuration key 'server.port' is not set in any source (active environment: prod).
Add it to flight.yaml or flight-prod.yaml, or set the FLIGHT_SERVER_PORT
environment variable.
```

```
flight.yaml:4:3: flow style ('[…]' / '{…}') is not supported by the Flight
YAML subset — quote the value if the character is literal
```

`ConfigError` and `ConfigLoadError` are both `Equatable` and conform to
`LocalizedError`, so they can be asserted on directly in tests and logged
through `localizedDescription` without losing the message.

## Interoperating

`Configuration.reader` hands the same layered stack to any library that takes
a swift-configuration `ConfigReader`, so an app configures its dependencies
from one stack rather than maintaining two:

```swift
let app = Application(configuration: configuration.reader)
```

Custom providers layer in at any precedence:

```swift
let configuration = try Configuration.load(
    additionalProviders: [remoteSecretsProvider]
)
```

## Two modules

`FlightConfig` is the runtime — the `Configuration` facade, the loader, the
provider bridge. This is what an application imports.

`FlightConfigCore` is the grammar and vocabulary: the YAML parser, `${VAR}`
substitution, `ConfigDecodable`, the error types, `FlightEnvironment`. It has
**no dependencies**, which matters because build tools link it to check
configuration keys at compile time, and a build tool's dependencies are paid
for by every consumer's build.

Importing `FlightConfig` re-exports `FlightConfigCore`, so applications get
the whole API from one import.

## What this is not

It does not fetch remote configuration, manage secrets, or reload at runtime.
Those are all provider concerns, and swift-configuration's provider protocol
is the seam for them — a remote-secrets provider layers in through
`additionalProviders` without this package growing to accommodate it.

## Documentation

```bash
SWIFT_CONFIG_BUILD_DOCS=1 swift package generate-documentation --target FlightConfig
```

## License

MIT. See [LICENSE](LICENSE).
