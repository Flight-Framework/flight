# ``FlightCore``

Dependency injection and application bootstrap, wired at compile time.

## Overview

A dependency container usually trades one problem for another: you stop
writing constructor plumbing, and you start finding out at 3am that a
component was never registered.

This one is wired by a build plugin that reads your sources, so a missing
registration or a dependency cycle is a build error rather than a runtime
surprise:

```swift
@Service
final class UserService: Sendable {
    @Inject var repository: any UserRepository
    @ConfigValue("features.signup_enabled", default: true) var signupEnabled: Bool
}
```

```swift
try await Flight.bootstrap(
    configuration: try Configuration.load(),
    modules: [WebModule.self, DataModule.self]
)
```

## Two phases

A ``Container`` is mutable while it registers and immutable afterwards, and
almost everything else follows from that.

During **registration**, modules run in dependency order and register what
they provide. Single-threaded by construction — no concurrency exists yet.

``Container/freeze()`` eagerly constructs every singleton and seals the
container. Afterwards, resolution is a dictionary read with no lock, safe from
any thread. A factory that was going to fail has already failed, during
startup, where someone is watching.

That is why resolution is cheap enough to do per request, and why registering
after `freeze()` is a programmer error rather than a supported operation.

## Components are Sendable

``Container/register(_:qualifier:scope:stereotype:factory:)`` and
``Container/resolve(_:qualifier:)`` both require `Sendable`.

A container that vends a mutable, non-`Sendable` singleton to two actors has
handed them a data race with no diagnostic at all. The container is precisely
where shared state becomes shared, so the requirement belongs here rather
than in a convention nobody can enforce.

For per-request mutable state, use ``Lifetime/scoped`` — one instance per
request, never shared between them.

## Topics

### Bootstrapping

- ``Flight``
- ``AssembledApplication``
- ``BootstrapError``

### The container

- ``Container``
- ``Lifetime``
- ``Scope``
- ``ResolutionError``

### Modules

- ``FlightModule``
- ``ModuleHealth``
- ``ModuleStatus``

### Introspection

- ``ComponentDescriptor``
- ``Stereotype``

### Transactions

- ``FlightTransactions``
- ``FlightTransactionToken``

### Guides

- <doc:Lifetimes>
- <doc:CompileTimeWiring>
