# ``FlightCore``

Dependency injection and application bootstrap, wired at compile time.

## Overview

A dependency container usually trades one problem for another: you stop
writing constructor plumbing, and you start finding out at 3am that a
component was never registered.

Flight wires dependencies with a build plugin that reads your sources, so a
missing dependency or a dependency cycle is a build error rather than a
runtime surprise — and there is no container to resolve against once the
process is running:

```swift
@Service
final class UserService: Sendable {
    @Inject let repository: any UserRepository
    @ConfigValue("features.signup_enabled", default: true) let signupEnabled: Bool
}
```

```swift
try await Flight.bootstrap(
    configuration: try Configuration.load(),
    modules: [WebModule.self, DataModule.self]
)
```

## Composition

Modules are values. A ``FlightModule`` holds what it provides — its stored
properties — and takes what it needs — its initializer parameters. A generated
*composition root* builds every module and component **once**, in dependency
order, wiring them by type. There is no registration step and no lookup.

Construction is **eager**, at composition: a `@ConfigValue` that fails to read,
or an initializer that throws, fails startup — where someone is watching —
rather than the first request unlucky enough to touch it. Afterwards every
component is a shared singleton, reached directly, so there is nothing to
resolve per request.

## Components are Sendable

A singleton is shared across every task in the process, so it must be
`Sendable`, and the compiler enforces it: a shared, mutable, non-`Sendable`
singleton handed to two tasks is a data race with no diagnostic at all.

Per-request mutable state does not belong on a singleton. It rides the request
context as a typed value — one copy per request, never shared between them.

## Topics

### Bootstrapping

- ``Flight``
- ``AssembledApplication``
- ``AssembledService``
- ``ServiceShutdownPhase``
- ``ServiceCompletionPolicy``
- ``BootstrapError``

### Modules

- ``FlightModule``
- ``ModuleHealth``
- ``ModuleStatus``
- ``ModuleHealthRegistry``

### Lifetime and resolution

- ``Lifetime``
- ``ResolutionError``

### Introspection

- ``ComponentDescriptor``
- ``Stereotype``

### Guides

- <doc:Lifetimes>
- <doc:CompileTimeWiring>
