# Flight Config

Layered, environment-aware configuration for Flight — a Spring Boot analogue
for server-side Swift. Implements the flight-config design doc: an immutable
`Configuration` resolved once at bootstrap from environment variables,
`flight-{env}.yaml`, and `flight.yaml`, with typed access via
`ConfigDecodable` and loud, specific failures for everything that can only go
wrong at runtime.

Built on Apple's [swift-configuration](https://github.com/apple/swift-configuration):
that package supplies the provider stack, the file/env/CLI/remote providers,
secret redaction, and access reporting; this one supplies the Flight-subset
YAML parser, the environment layering, and the §5 failure contract. Flight
Core depends on it and re-exports it, so app code normally just
`import FlightCore`.

## Two targets

| Target | Contains | Depends on |
|---|---|---|
| `FlightConfigCore` | the YAML parser, `${VAR}` substitution, `ConfigDecodable`, the error types, `FlightEnvironment`, the `ConfigSource` protocol | **nothing** |
| `FlightConfig` | the `Configuration` facade, `FlightYAMLSnapshot`/`FlightYAMLProvider`, the loader | `FlightConfigCore`, swift-configuration |

The split exists so Flight Core's `flight-registration-gen` build tool can
link the parser for its compile-time `@ConfigValue` key check without dragging
swift-configuration (and swift-system, swift-collections,
swift-service-lifecycle) into every consumer's build graph. It is a
build-graph concern only: `FlightConfig` re-exports `FlightConfigCore`, so
`import FlightConfig` still yields the whole API.

## Build status

Builds and passes all tests — verified 2026-08-21 against Swift 6.2.3 on
Linux (x86_64): `swift build` clean, 102/102 swift-testing tests green,
including process-exit tests for trap semantics and the provider-interop
suite. Flight Core builds and passes its 56 + 16 tests against it unchanged.
Wired into Flight Core (`../../Core/flight-core`) as a path dependency;
Core's own suites and the flight-demo tour exercise the integration end to
end.

## Quick start

```swift
import FlightCore  // re-exports FlightConfig; or `import FlightConfig` alone

@main struct Main {
    static func main() async throws {
        // Steps 1–5 of the bootstrap sequence (§6): FLIGHT_ENV, flight.yaml,
        // flight-{env}.yaml, env vars → one immutable Configuration.
        let configuration = try Configuration.load()
        try await bootstrap(configuration: configuration, modules: [AppModule.self])
    }
}
```

```yaml
# flight.yaml — base layer, shared by every environment
datasource:
  url: "postgres://localhost:5432/flight_dev"
  pool_size: 5
server:
  port: 8080
```

```yaml
# flight-prod.yaml — active when FLIGHT_ENV=prod, overrides key-by-key
datasource:
  url: "${FLIGHT_DATASOURCE_URL}"   # env-var substitution at load time
  pool_size: 50
```

Components read config through the `@ConfigValue` macro (declared in Flight
Core, resolved against this package's `Configuration`):

```swift
@Component
struct DataSourceFactory {
    @ConfigValue("datasource.url") var url: String
    @ConfigValue("datasource.pool_size", default: 10) var poolSize: Int
}
```

Or imperatively, anywhere the `Configuration` value (or component) is in hand:

```swift
let url: URL = try configuration.get("datasource.url")
let poolSize = configuration.get("datasource.pool_size", default: 10)
let certPath: String? = try configuration.getIfPresent("tls.cert_path")
```

## Precedence (§3)

Highest first; the merge is **key-by-key**, so an override file only shadows
the keys it names:

1. **Environment variables** — `datasource.url` reads `FLIGHT_DATASOURCE_URL`
   (fixed transform: uppercase, `.` → `_`, `FLIGHT_` prefix). The deploy-time
   escape hatch; always wins.
2. **`flight-{env}.yaml`** — `{env}` from `FLIGHT_ENV` (`dev`, `test`,
   `staging`, `prod`; unset → `dev`). A missing file is not an error.
3. **`flight.yaml`** — base defaults. Required by `Configuration.load`
   (env-var-only apps can assemble
   `Configuration(sources: [EnvironmentVariablesSource()])` by hand).

## Compile-time vs. runtime validation (§5)

The project-wide rule: what is statically knowable is a compile error;
throwing is reserved for genuinely runtime-only unknowns.

- **Compile time** — a `@ConfigValue` key with no `default:` is checked
  against `flight.yaml` by Flight Core's `FlightRegistrationPlugin` during
  the build, using this package's own parser (build and runtime can never
  disagree about what keys a file defines). Missing → build error at the
  `@ConfigValue` site. Typo'd keys never reach a binary.
- **Runtime** — a key whose value depends on the active environment (which
  `flight-{env}.yaml` got selected, what an env var actually holds) throws
  `ConfigError.missingKey`/`.decodingFailed` during bootstrap, naming the
  key, the active environment, and the env var that would satisfy it.
- **Load time** — unreadable/invalid files and unresolved `${VAR}`
  substitutions throw `ConfigLoadError` before a `Configuration` exists.
  An unresolved substitution fails the load rather than letting the key fall
  through to a lower layer — the alternative is prod silently running on the
  base file's dev values.

### Accessor semantics at a glance

| Accessor | absent | present, malformed |
|---|---|---|
| `get(_:as:) throws` | throws `missingKey` | throws `decodingFailed` |
| `get(_:default:)` | returns default | **traps** (never masks corruption) |
| `getIfPresent(_:as:) throws` | `nil` | throws `decodingFailed` |

`@ConfigValue("key", default: v)` expands through `getIfPresent … ?? (v)`,
so a malformed value fails the owning module's `configure(_:)` loudly
instead of trapping or silently taking the default.

## Typed access

`ConfigDecodable` ships for `String`, `Int`, `Bool`, `Double`, `URL`.
`Bool` accepts `true/false`, `yes/no`, `on/off`, `1/0` (case-insensitive);
numeric types tolerate surrounding whitespace. Custom types conform with one
failable initializer:

```swift
enum LogLevel: String, ConfigDecodable {
    case debug, info, warn, error
    init?(configValue: String) { self.init(rawValue: configValue) }
}
```

## The YAML subset

Config files are parsed by a self-contained subset parser (`FlightYAML`),
kept deliberately small and **loud about its edges** — anything outside the
subset is a clear parse error naming the construct and the alternative,
never a silent misread.

Supported: block mappings and sequences (indentation-based, spaces only),
plain / single-quoted / double-quoted scalars (with the usual escapes),
comments, quoted keys, explicit and implicit nulls, one optional `---` /
`...` marker pair, CRLF files. Sequences flatten by index
(`hosts.0`, `hosts.1`); a null value means "this layer says nothing about
this key" (an explicit `""` is a present, empty value); duplicate keys and
dotted-key/nesting collisions are errors.

Rejected with a specific error: flow style (`[a, b]` / `{a: b}`), block
scalars (`|`/`>`), anchors/aliases/tags/merge keys, directives, multiple
documents, tab indentation, multi-line plain scalars.

### `${VAR}` substitution (§8)

A load-time convenience for referencing env vars from static config — not a
secrets manager (secrets belong in the env-var layer, sourced from the
deployment platform):

- `${VAR}` — the variable's value; **unset fails the load**
  (`ConfigLoadError.unresolvedSubstitution`)
- `${VAR:-default}` — fallback when unset *or empty* (bash `:-` semantics)
- `$$` — literal `$`; a `$` not followed by `{` needs no escaping

Substitution applies to values only (never keys), after quote processing.

## Testing (§7)

Unit-style — hand a test exactly the keys it needs:

```swift
@Test
func dataSourceUsesConfiguredPoolSize() throws {
    let config = Configuration(sources: [
        TestConfigSource(["datasource.pool_size": "3"])
    ])
    #expect(try config.get("datasource.pool_size", as: Int.self) == 3)
}
```

Integration-style — `test` is a first-class `FlightEnvironment` case so
`flight-test.yaml` can live alongside the other files, and every `load`
parameter is injectable (directory, environment, process-environment
dictionary), making full loads reproducible without touching global state:

```swift
let config = try Configuration.load(
    from: fixtureDirectory,
    processEnvironment: ["FLIGHT_ENV": "test"]
)
```

## Layout

```
Sources/FlightConfigCore/         no dependencies — also linked by the build tool
  FlightYAML.swift                the subset parser
  FlightYAMLDocument.swift        parse + flatten + substitute; `keys` for tooling
  EnvironmentSubstitution.swift   ${VAR} / ${VAR:-default} engine
  ConfigDecodable.swift           typed decoding + std conformances
  ConfigError.swift               ConfigError (resolution) + ConfigLoadError (load)
  FlightEnvironment.swift         FLIGHT_ENV resolution (§4)
  FlightConfigFiles.swift         flight.yaml / flight-{env}.yaml names
  ConfigSource.swift              the pre-migration source protocol
  YAMLConfigSource.swift          a document as a ConfigSource
  EnvironmentVariablesSource.swift  the FLIGHT_* key transform
  TestConfigSource.swift          in-memory source for tests (§7)

Sources/FlightConfig/             + swift-configuration
  Configuration.swift             the facade: typed accessors over a provider stack
  ConfigurationLoader.swift       Configuration.load — bootstrap steps 1–5
  FlightYAMLSnapshot.swift        FlightYAML as a FileConfigSnapshot
  FlightYAMLProvider.swift        serves a parsed snapshot without async
  ConfigSourceProvider.swift      ConfigSource → ConfigProvider bridge
  Exports.swift                   re-exports FlightConfigCore

Tests/FlightConfigTests/          102 tests: grammar, rejections, substitution,
                                  precedence, loader integration, trap semantics,
                                  provider interop
```

## Beyond the base layering

`Configuration` is an ordered stack of swift-configuration **providers**, so
anything that ecosystem grows plugs straight in — the §8 extension point,
delivered by someone else's code:

```swift
let configuration = try Configuration.load(
    // Inserted above the env-var layer, so they win.
    additionalProviders: [
        DirectoryFilesProvider(directoryPath: "/run/secrets"),  // K8s / Docker secrets
        CommandLineArgumentsProvider(),
    ],
    secrets: .specific(["FLIGHT_DATASOURCE_PASSWORD"]),
    accessReporter: AccessLogger(logger: logger)
)
```

- **Secrets** — `secrets:` marks env vars sensitive, so they redact to
  `<REDACTED>` in access logs and in `configuration.debugDescription`. Vaults
  remain the platform's job, but a third-party provider (AWS Secrets Manager,
  Vault) is now a list entry rather than a fork.
- **Access reporting** — `accessReporter:` receives an event per resolved key:
  which provider won, under what encoded key, and whether conversion failed.
- **Diagnostics** — `description` summarizes the stack (which layers, how many
  keys each, highest precedence first) and prints no values, so it is always
  safe to log; `debugDescription` adds the values, secret-marked ones redacted.
- **Hot reloading** — still not what `Configuration` does: it is immutable
  post-bootstrap by design, matching Flight Core's frozen-`Container`
  decision, and config change means restart. But `FlightYAMLSnapshot`
  conforms to `FileConfigSnapshot`, so
  `ReloadingFileProvider<FlightYAMLSnapshot>` exists for code that genuinely
  wants to watch a file, and it parses the same subset with the same errors.

### Handing config to other libraries

`configuration.reader` yields a swift-configuration `ConfigReader` — the type
Vapor, Hummingbird, and the Swift Temporal SDK accept — so those libraries
read from the same layered stack rather than a second one.

One semantic caveat at that boundary, and the reason Flight's own code never
resolves through it: a reader's optional and `default:` accessors **swallow**
type-conversion errors, returning nil or the default where `get`/`getIfPresent`
fail loudly. That is the reader's documented contract, not a defect — but it
is the §5 failure mode, so keep it on the far side of the handoff.

## Non-goals (§8)

- No hot reloading in `Configuration` itself — see above for the escape hatch.
- No secrets *storage* — `${VAR}` substitution references env vars, `secrets:`
  redacts them; vaults are the platform's job.

## Design deltas vs. the design doc

All additive or narrowing, none silent:

| Delta | Why |
|---|---|
| `ConfigError.missingKey` carries `(key:environment:)`, not a bare `String` | §5 requires the runtime error to "identify the key **and the active environment**"; the payload is where that has to live. |
| `getIfPresent(_:as:)` added beside the two spec'd accessors | "Absence means feature off" config (optional TLS cert path) has no default value to hand `get(_:default:)`; also what `@ConfigValue default:` expands through so malformed values throw rather than trap. |
| Not a leaf package any more — depends on swift-configuration | The §8 non-goals (remote sources, secrets, reload) all reduce to "someone else's provider" once the stack is Apple's. `FlightConfigCore` keeps the zero-dependency property where it actually pays: the build tool. |
| Resolution walks providers asking `.string`, then `.int`/`.double`/`.bool` | swift-configuration's lookup is type-directed, and a provider holding a typed value refuses a `.string` request rather than stringifying it. Asking only for `.string` would read every JSON/TOML integer as **absent** and silently resolve it from a lower layer — §5's exact failure mode. The retry is what keeps third-party providers usable. |
| `Configuration` is a facade, not a `ConfigReader` typealias | A reader's optional/`default:` accessors swallow type-conversion errors. Flight resolves through the provider API, where a malformed value throws, and applies `ConfigDecodable` itself. |
