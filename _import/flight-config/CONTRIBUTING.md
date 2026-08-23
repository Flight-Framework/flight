# Contributing

Thanks for your interest in flight-config.

## Getting set up

```bash
git clone https://github.com/Swift-Flight/flight-config
cd flight-config
swift build
swift test
```

No services or environment variables are required — the whole suite runs
in-process in well under a second. Tests that need the process environment
use an injected dictionary rather than mutating the real one, so they are
safe to run in parallel.

## Before opening a pull request

```bash
swift build -Xswiftc -warnings-as-errors
swift test
SWIFT_CONFIG_BUILD_DOCS=1 swift package generate-documentation \
    --target FlightConfig --warnings-as-errors
```

CI runs exactly these, on Linux and macOS, against Swift 6.2.

Swift 6.2 is the floor because swift-configuration declares tools version
6.2; this package cannot go lower while depending on it.

## The rule that governs most decisions here

**A configuration must never be silently wrong.** When a choice is between
failing loudly and continuing with a plausible value, this library fails
loudly. Concretely, that is why:

- An unresolved `${VAR}` fails the whole load rather than letting the key
  fall through to the base layer.
- A provider that holds a key but cannot render it stops resolution rather
  than allowing a lower layer to answer.
- The YAML subset rejects anything it does not fully understand rather than
  guessing.
- `get(_:default:)` traps on a malformed value rather than substituting the
  default.

A change that softens one of these needs to argue why the silent path is
safe, not just more convenient.

## The two modules

`FlightConfigCore` **has no dependencies and must keep it that way.** Build
tools link it to check configuration keys at compile time, and a build tool's
dependencies are paid for by every consumer's build. If something needs
swift-configuration, it belongs in `FlightConfig`.

## What we look for

Tests that assert behavior rather than shape. Doc comments with runnable
examples on anything non-obvious. Error messages that name the key, the file,
and the fix — every existing message does, and a new one should too.
