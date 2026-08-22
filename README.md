# Flight Core

The DI container and compile-time-first registration layer of Flight — a
Spring Boot analogue for server-side Swift. Implements the flight-core design
doc: two-phase `Container`, `Scope`, `FlightModule` + deterministic module
DAG, `@Component` (+ `@Service`/`@Repository` stereotypes, §5.1.1) /
`@Autowired`/`@ConfigValue`/`@Transactional` macros, the
`FlightRegistrationPlugin` build plugin, ServiceLifecycle-based bootstrap, and
introspection (`ComponentDescriptor`, `ModuleHealth`).

## Build status

**Builds and passes all tests** — verified 2026-07-15 against Swift 6.2.3 on
Linux (x86_64): `swift build` clean, 59/59 tests green (43 swift-testing
runtime tests, 16 XCTest macro fixtures), and the §10 spike probes executed
(results recorded in SPIKE-FINDINGS.md → "Empirical run results").

**Flight Config is wired in** (2026-07-14): the placeholder `Configuration`
seam (delta 5) is resolved — Core now depends on the real package at
[`../../Config/flight-config`](../../Config/flight-config/README.md) and
re-exports it, so `import FlightCore` provides the full config API
(`Configuration.load()`, YAML layering, `FlightEnvironment`, sources).
With it came the rest of the Flight Config §5 surface: `@ConfigValue` gained
the `default:` form, and `FlightRegistrationPlugin` now checks no-default
`@ConfigValue` keys against the app's `flight.yaml` at build time — a
missing key is a compile error at the property, not a startup surprise.

The package was originally written to spec without a toolchain; the shakedown
run needed only four mechanical fixes, all recorded in SPIKE-FINDINGS.md:
`@MainActor` on two generator helpers, a `sending`-compliant instance box in
`Scope`, the fixture harness moving to `macroSpecs:` (so declared conformances
reach the extension macro), and the predicted one-pass fixture whitespace
alignment. The feared swift-syntax / PackagePlugin / ServiceLifecycle API
churn did not materialize.

Constraints surfaced by the run (details in SPIKE-FINDINGS.md):

- **M-2**: `@Component`'s generated `init(_flight:)` suppresses a type's
  implicit default `init()`; construct components by hand via
  `try T(_flight: container)` or declare an init.
- **M-3**: non-injected stored properties of a `@Component` need default
  values; `@Component` diagnoses this at the property (`component.uninitialized`).
- **Delta 9**: `FlightModule.serviceCompletion` (default `.failsApp`) lets a
  bounded one-shot service end the app gracefully instead of failing the group.

A runnable end-to-end tour — including the build plugin, which nothing in the
test suite exercises — lives in [`../flight-demo`](../flight-demo/README.md)
(`swift run` from that directory).

**Registration-scan generalization** (2026-07-15, for Flight Web §4): the
generator's source scan now recognizes `@Controller` alongside `@Component`
(`ComponentVisitor.registrableAttributes`) — the "one registration pipeline,
different entry kinds" extension point. Name-level only; Core references no
Flight Web types.

**Ambient-scope fallback** (2026-07-17, delta 12): plain `resolve` — the call
`@Autowired` expands to — now rides the ambient scope for `.scoped`
registrations, so a `.scoped` component can `@Autowired` another `.scoped` component
(`@Service(scope: .scoped)` over a scoped repository, the shape Flight Data
needs). Previously only hand-written factories could bridge this, via
`resolveInActiveScope` (delta 11). Resolving a scoped component with *no* ambient
scope still throws `scopeRequired`, so captive dependencies still fail loudly
at `freeze()`. Pinned by `AmbientFallbackTests`.

**Async-native transactions** (2026-07-17, delta 14): the "sync vs async
coordinator" open question is resolved. `FlightAsyncTransactionCoordinator` +
`FlightTransactions.asyncCoordinator` (nil-default task-local) let a
datasource offer awaited begin/commit/rollback; `@Transactional` on an
*async* method routes through `begin/commit/rollbackPreferringAsync` — the
async-native coordinator when bound, the sync coordinator otherwise — so
async transactional work no longer rides a thread-blocking bridge. Sync
methods and their expansion are unchanged.

**Stereotypes** (2026-07-15, design §5.1.1): `@Service` and `@Repository`
live in Core and expand *identically* to `@Component` — same
`_FlightRegistrable` marker, same thunk — tagging the registration with a
`Stereotype` carried on `ComponentDescriptor` (Actuator groups its dashboard by
layer; the tag is also the pointcut for any future default AOP policy).
Hand registrations take `register(_:qualifier:scope:stereotype:)`, defaulting
to `.component`. The `@Controller` *macro* is Flight Web's; Core holds only
the enum case and the generator scan. Delta 10 in SPIKE-FINDINGS.md.

## Requirements

- Swift 6.1+ toolchain (`@attached(body)` for `@Transactional` shipped in 6.0;
  the plugin URL APIs and tools-version want 6.1).
- macOS 15+ or Linux with a Swift 6.1 toolchain.

## Build & test

```sh
swift build
swift test                                   # runtime + macro fixture suites
./spikes/BuildPluginSpike/run-spike.sh       # empirical §10 probes (see EXPECTED.md)
```

## Using it

```swift
import FlightCore

@Component
final class GreetingService {
    @ConfigValue("greeting.name") let name: String          // required — build-checked against flight.yaml
    @ConfigValue("greeting.excitement", default: 1) let excitement: Int
    func greet() -> String { "hello, \(name)" + String(repeating: "!", count: excitement) }
}

@Component
public final class Greeter {
    @Autowired let service: GreetingService
}

struct AppModule: FlightModule {
    func configure(_ container: Container) throws {
        // Generated by FlightRegistrationPlugin from every @Component in
        // this target + Flight-based dependency targets:
        try flightRegisterAll(container)
    }
}

@main struct Main {
    static func main() async throws {
        try await bootstrap(
            // FLIGHT_ENV → flight.yaml + flight-{env}.yaml + FLIGHT_* env
            // vars, resolved once into an immutable value (Flight Config).
            // Tests use Configuration(values: ["greeting.name": "flight"]).
            configuration: try Configuration.load(),
            modules: [AppModule.self]
        )
    }
}
```

Wire the plugin on the app target:

```swift
.executableTarget(
    name: "App",
    dependencies: [.product(name: "FlightCore", package: "flight-core")],
    plugins: [.plugin(name: "FlightRegistrationPlugin", package: "flight-core")]
)
```

## Layout

```
Sources/FlightCore/            runtime: Container, Scope, modules, bootstrap,
                               transactions seam, macro declarations
Sources/FlightCoreMacrosImpl/  compiler plugin: Component/Autowired/ConfigValue/
                               Transactional implementations
Sources/flight-registration-gen/  SwiftParser-based codegen tool
Plugins/FlightRegistrationPlugin/ build tool plugin invoking the tool
Tests/FlightCoreTests/         swift-testing runtime suites (+ Support/LoggingModule,
                               the §4-mandated second FlightModule conformance)
Tests/FlightCoreMacroTests/    the §5.4 fixture suite — normative expansions
spikes/BuildPluginSpike/       ready-to-run §10 probes + EXPECTED.md predictions
SPIKE-FINDINGS.md              research-backed spike answers + design deltas
```

## Deliberately not here

Flight Web/NIO transport, Actuator endpoints, and real transaction
coordinators (Flight Data). Core registers no opinion about any of them
beyond the seams they plug into. (Flight Config *used* to be on this list as
a placeholder seam — it is now the real package at
`../../Config/flight-config`, and Core's `Configuration.swift` is just the
re-export.)
