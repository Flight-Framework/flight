# Contributing

Thanks for your interest in flight-core.

## Getting set up

```bash
swift build
swift test
```

No services or environment variables. The generator tests build and invoke
the real `flight-registration-gen` executable, so the first run takes a little
longer.

## Before opening a pull request

```bash
swift build -Xswiftc -warnings-as-errors
swift test
swift-format lint --recursive Sources Tests Plugins
FLIGHT_CORE_BUILD_DOCS=1 swift package generate-documentation \
    --target FlightCore --warnings-as-errors
```

## What governs decisions here

**This package is the floor.** Ten other libraries depend on it, so an API
change here is an API change everywhere. That makes source-breaking changes
cheap now and very expensive after 1.0 — if something is wrong, the time to
say so is before the tag.

**Failures belong at build time, then startup, then never at request time.**
The build plugin catches what it can, and eager construction at composition
catches the rest during startup — every component is built once, up front, so
nothing is left to fail for wiring reasons at request time.

**Composition will not wire a data race.** A singleton is shared across every
task in the process, so it must be `Sendable`, and the compiler enforces it.
Shared state becomes shared at composition, so that is where the requirement is
enforced rather than left to a convention.

**Traps are for programmer errors that cannot be recovered from.** A module
whose initializer needs values — one that cannot be built from its type alone —
traps if something constructs it directly instead of through the composition
root. Recoverable conflicts throw instead: a duplicate route or an undeclared
lane fails the bootstrap sequence with a message.

## Testing

`FlightCoreTests` covers the container, scopes, module ordering, and
bootstrap. `FlightCoreMacroTests` pins macro expansions as fixtures — treat
those as normative; if an expansion changes, that is an API change.

`FlightRegistrationGenTests` drives the generator end to end: a manifest in, a
generated file and diagnostics out. That is the contract a broken build would
break, so test it there rather than through internal functions.
