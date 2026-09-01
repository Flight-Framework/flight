# flight-core

Dependency injection and application bootstrap for Swift servers.

Components declare themselves with an attribute. A build plugin wires them
together and checks the graph at compile time. Bootstrap builds the container
once, freezes it, and runs your services under a `ServiceGroup`.

```swift
@Service
final class UserService: Sendable {
    @Inject var repository: any UserRepository
    @ConfigValue("features.signup_enabled", default: true) var signupEnabled: Bool
}

@main
struct App {
    static func main() async throws {
        try await Flight.bootstrap(
            configuration: try Configuration.load(),
            modules: [WebModule.self, DataModule.self]
        )
    }
}
```

## Installation

```swift
dependencies: [
    .package(url: "https://github.com/Flight-Framework/flight.git", from: "0.11.0")
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

## Two phases, and why it matters

A container is mutable while it registers and immutable afterwards.

**Registration.** Modules run in dependency order and register what they
provide. Single-threaded, by construction — no concurrency exists yet.

**Frozen.** `freeze()` eagerly constructs every singleton, then seals the
container. From that point resolution is a dictionary read with no lock, safe
from any thread, and a factory that was going to fail has already failed —
during startup, where you can see it.

That split is what makes resolution cheap enough to do per request, and it is
why a registration after `freeze()` is a programmer error rather than a
supported operation.

## Components are `Sendable`

`register` and `resolve` both require it. A dependency container that vends a
mutable, non-`Sendable` singleton to two actors has handed them a data race
with no diagnostic — the container is exactly the place where shared state
gets shared, so the requirement belongs here.

```swift
@Service final class UserService: Sendable { }        // ✅
final class Counter { var count = 0 }                 // ❌ won't compile
```

For per-request mutable state, use `.scoped` — one instance per request,
never shared across them.

## Lifetimes

| Lifetime | One instance per | Constructed |
|---|---|---|
| `.singleton` | application | eagerly, at `freeze()` |
| `.scoped` | request (or explicit `Scope`) | on first resolve in the scope |
| `.transient` | resolution | every time |

Resolving a `.scoped` component with no active scope throws rather than
silently handing back a singleton — the captive-dependency bug is a real one
and it is worth a hard error.

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

> The plugin is a `BuildToolPlugin` and runs under SwiftPM. Xcode projects do
> not run it, so an Xcode-only target needs its registrations written by hand.

## Modules

A module declares what it needs and registers what it provides:

```swift
struct DataModule: FlightModule {
    static let dependencies: [any FlightModule.Type] = [ConfigModule.self]

    func configure(_ container: Container) throws {
        container.register(DataSource.self, scope: .singleton) { c in
            PostgresDataSource(configuration: try c.resolve(Configuration.self))
        }
    }
}
```

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

`Flight.assemble` builds and freezes without running anything:

```swift
let app = try Flight.assemble(configuration: config, modules: [AppModule.self])
let service = try app.container.resolve(UserService.self)
```

Swapping in a test double uses `override`, which replaces a registration
made earlier rather than adding a second one:

```swift
let container = try TestContainer.build { AppModule() } overriding: { container in
    container.override((any UserRepository).self, scope: .scoped) { _ in InMemoryUsers() }
}
```

A plain second `register` for the same key is *not* the way: duplicate
registrations fail `freeze()` with `duplicateRegistration`, deliberately, and
`override` exists precisely because they do. It is order-independent — the
override may be declared before or after the registration it replaces — and
it is test-facing API; production code has no reason to reach for it.

## Documentation

```bash
FLIGHT_CORE_BUILD_DOCS=1 swift package generate-documentation --target FlightCore
```

## License

MIT. See [LICENSE](LICENSE).
