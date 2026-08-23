# Compile-time wiring

What the build plugin checks, and what to do when it complains.

## Overview

A build plugin scans your sources, generates the registration code, and
checks the graph before anything runs. The point is that the failures a DI
container is famous for — a component nobody registered, a cycle nobody
noticed — become build errors.

```swift
.target(
    name: "MyApp",
    dependencies: [.product(name: "FlightCore", package: "flight-core")],
    plugins: [.plugin(name: "FlightRegistrationPlugin", package: "flight-core")]
)
```

## What it checks

**Missing registrations.** An `@Autowired` property whose type is not a
scanned component is reported, naming the type.

**Dependency cycles.** Reported with the cycle spelled out, so you can see
which edge to break.

**`@ConfigValue` keys.** Checked against `flight.yaml`. A typo in a
configuration key is a build error rather than a startup failure.

**Existential bridges.** A protocol with exactly one conformer is resolvable
as `any Protocol` with no hand-written glue:

```swift
protocol UserRepository: Sendable {}

@Repository
final class PostgresUserRepository: UserRepository, Sendable {}

@Service
final class UserService: Sendable {
    @Autowired var repository: any UserRepository   // wired automatically
}
```

Two conformers is genuine ambiguity, and the plugin declines to guess. Add a
qualifier, or register the bridge yourself.

## Hand-registered components

Not everything is scanned. A component registered inside a module's
`configure(_:)` — a third-party type, something built from configuration — is
invisible to a source scanner.

Acknowledge it, and the check stays quiet:

```swift
// flight:hand-registered
@Autowired var external: SomethingFromAnotherLibrary
```

The comment goes on the **property**, not the type. It is deliberately a
comment rather than an attribute: it is a note to the checker, not a change
to the program.

## Limits worth knowing

**Nested types are not scanned.** A `@Component` declared inside another type
is skipped silently, and will fail at startup with `notRegistered`. Declare
components at file scope.

**Matching is by base name.** Two modules each with a `UserService` look like
one type to the checker. Registration itself is unambiguous — it keys on type
identity — so this affects diagnostic quality, not correctness.

**Xcode does not run it.** The plugin is a `BuildToolPlugin`, which SwiftPM
runs and Xcode projects do not. An Xcode-only target needs its registrations
written by hand.

## When the plugin is wrong

It is a checker, not an oracle. If it reports a missing registration for
something you register by hand, the marker comment is the intended answer —
not disabling the plugin. If it reports a cycle you believe is not one, the
cycle is usually real and mediated by a type you forgot participates.
