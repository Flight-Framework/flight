# flight-core

Dependency injection and application bootstrap for Swift servers.

Components declare themselves with an attribute. A build plugin wires them
together and checks the graph at compile time. Bootstrap builds every module
and component once, at composition, and runs your services under a
`ServiceGroup`.

```swift
@Service
final class UserService: Sendable {
    @Inject let repository: any UserRepository
    @ConfigValue("features.signup_enabled", default: true) let signupEnabled: Bool
}

@main
struct App {
    static func main() async {
        await Flight.run(
            configuration: try Configuration.load(),
            modules: [WebModule.self, DataModule.self]
        )
    }
}
```

## Installation

```swift
dependencies: [
    .package(url: "https://github.com/Flight-Framework/flight.git", from: "0.14.0")
]
```

```swift
.target(
    name: "MyApp",
    dependencies: [.product(name: "FlightCore", package: "flight")],
    plugins: [.plugin(name: "FlightRegistrationPlugin", package: "flight")]
)
```

Requires Swift 6.2+. Linux and macOS 15+.

`Flight.run` is `bootstrap` that does not throw: it starts the application,
and if it *cannot* start it prints why and exits `1`. A `main` that throws
instead reports the same message under `Fatal error: Error raised at top
level`, a backtrace and a `Signal 4` — a configuration typo dressed as a
crash. `bootstrap` remains for embedders that want the error rather than the
exit.

## Two phases, and why it matters

The graph is built all at once, then never changes.

**Composition.** At startup the generated composition root builds every module
and component once, in dependency order, and wires what each provides into
whatever injects it — by type. Single-threaded, by construction — no
concurrency exists yet.

**Running.** From that point the graph is immutable, so reaching a dependency
is a stored-property read with no lock, safe from any thread, and a
constructor that was going to fail has already failed — during startup, where
you can see it.

Building the whole graph once, up front, is what lets a request reach its
dependencies with no lookup at all, and it is why the graph is fixed after
composition rather than something a running application adds to.

## Components are `Sendable`

A singleton is built once and shared for the whole application, reachable from
every thread that serves a request. A mutable, non-`Sendable` component shared
between two actors would be a data race with no diagnostic — composition is
exactly the place where shared state gets shared, so the requirement belongs
here.

```swift
@Service final class UserService: Sendable { }        // ✅
final class Counter { var count = 0 }                 // ❌ won't compile
```

For per-request mutable state, carry it on `RequestContext` — it rides the
request as a typed value, not a shared component.

## Lifetimes

Singleton is the only lifetime: a component is built **once**, by the
composition root, and shared for the application's lifetime. There is no
`.scoped` or `.transient` — per-request state rides `RequestContext`, and a
pooled connection is leased per operation, so nothing needed them and their
captive-dependency class of bug went with them. See <doc:Lifetimes>.

## Compile-time wiring

The build plugin scans your sources, generates the registration code, and
checks the graph before anything runs:

- **Missing registrations** are reported at build time, not at first request.
- **Dependency cycles** are reported with the cycle named.
- **`@ConfigValue` keys** are checked against `flight.yaml`.
- **Existential bridges** are synthesized: a protocol with exactly one
  conformer is resolvable as `any Protocol` without hand-written glue.

A component that is registered by hand rather than scanned is acknowledged
with a comment, so the check does not have to choose between false positives
and silence:

```swift
// flight:hand-registered
@Inject var external: SomethingFromAnotherLibrary
```

### Types their own module registers

The scan covers your target *and every Flight-based package it links*. That is
usually what you want, but some types must not be registered just because a
package is linked: whether they should exist at all is a runtime question —
a configuration gate, or an optional subsystem the app may not have included.

Mark those with `flight:module-registered`, above the declaration:

```swift
// flight:module-registered — FlightSecurityModule registers this.
@Middleware
public struct Authentication: Sendable {
    @Inject var validator: (any TokenValidator)
}
```

The type is still scanned — its dependencies are still checked, and `@Inject`
of it still resolves without a warning — but the composition root does not
build it as a graph node of its own, and it is never chosen as an existential
bridge conformer. Its module provides it instead. The generated file names
every type it skipped for this reason, so nothing disappears silently.

Why it matters: a component is built eagerly, at composition. `Authentication`
injects `(any TokenValidator)`, which only a security module provides, so
without the marker any app that merely *linked* the security package could not
compose and never booted.

> The plugin is a `BuildToolPlugin` and runs under SwiftPM. Xcode projects do
> not run it, so an Xcode-only target needs its registrations written by hand.

## Modules

A module declares what it needs and *holds* what it provides, built in its
initializer:

```swift
struct DataModule: FlightModule {
    static let dependencies: [any FlightModule.Type] = [ConfigModule.self]

    let dataSource: DataSource
    init(configuration: Configuration) throws {
        self.dataSource = PostgresDataSource(configuration: configuration)
    }
}
```

The composition root builds each module in dependency order and wires what one
provides into whatever injects it, by type.

Order is resolved from the declared dependencies and is deterministic: the
same module set always produces the same order. A cycle is a startup error
naming the modules involved.

## Transactions

Transactions belong to your data layer, not to Core. With Hangar:

```swift
try await repo.transaction { tx in
    try await tx.debit(from, amount)
    try await tx.credit(to, amount)   // a throw here rolls back the debit
}
```

Returning commits; throwing rolls back. Nested `transaction { }` calls become
savepoints. The closure receives a `Repo` bound to the transaction's
connection — use it, not the outer repo, or the work runs outside the
transaction. Isolation level and retry-on-serialization-failure are arguments:
`transaction(isolation: .serializable, retryingOnSerializationFailure: 3)`.

Core previously offered a `@Transactional` macro that wrapped a method body
against an ambient coordinator. It was removed: the boundary it created was
invisible at the call site, its nesting semantics had to *guess* whether a
transaction was already open (a guess that could silently turn a rollback into
a durable commit), and it could express neither isolation levels nor retry.
An explicit closure makes the boundary and its extent visible in the code that
opens it.

## Testing

`Flight.assemble` composes the modules and returns their services, without
running anything:

```swift
let app = try Flight.assemble(configuration: config, modules: [appModule])
```

A component takes what it needs as `@Inject` parameters, so swapping in a test
double is just constructing it with one — no container to override:

```swift
let service = UserService(repository: InMemoryUsers())
```

That is the whole of it: a test builds the type under test with fakes passed
in, and never reaches for framework wiring to do it.

## Documentation

```bash
FLIGHT_CORE_BUILD_DOCS=1 swift package generate-documentation --target FlightCore
```

## License

MIT. See [LICENSE](LICENSE).
