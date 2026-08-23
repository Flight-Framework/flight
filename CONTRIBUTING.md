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
The build plugin catches what it can, eager singleton construction catches the
rest during bootstrap, and resolution after `freeze()` is a pure read that
cannot fail for wiring reasons.

**The container will not vend a data race.** `register` and `resolve` require
`Sendable`. A container is where shared state becomes shared, so that is where
the requirement is enforced rather than left to a convention.

**Traps are for programmer errors that cannot be recovered from.** Registering
after `freeze()` traps because no recovery exists. A duplicate registration
throws, because generated and hand-written code can legitimately collide and
the bootstrap sequence can report it.

## Testing

`FlightCoreTests` covers the container, scopes, module ordering, and
bootstrap. `FlightCoreMacroTests` pins macro expansions as fixtures — treat
those as normative; if an expansion changes, that is an API change.

`FlightRegistrationGenTests` drives the generator end to end: a manifest in, a
generated file and diagnostics out. That is the contract a broken build would
break, so test it there rather than through internal functions.
