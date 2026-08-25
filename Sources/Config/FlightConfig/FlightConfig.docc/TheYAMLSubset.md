# The YAML subset

What the parser accepts, what it refuses, and why the refusals are the
point.

## Overview

Full YAML is a large language with several ways to write the same thing and a
few famous ways to write something you did not mean. A configuration file
does not need that surface — it needs to be unambiguous.

So this parser accepts a deliberately small subset, and rejects everything
else with a message naming the construct and the alternative. Anything it
does not fully understand is a loud failure at load, never a value that means
something unexpected at runtime.

## What is supported

**Nested maps**, to any depth:

```yaml
server:
  http:
    port: 8080
    host: 0.0.0.0
```

Keys flatten with dots: `server.http.port`.

**Sequences**, addressed by index:

```yaml
cluster:
  hosts:
    - alpha
    - beta
```

Flattens to `cluster.hosts.0` and `cluster.hosts.1`. Read the whole array
through ``Configuration/reader``.

**Scalars** — strings, integers, doubles, booleans — quoted or bare:

```yaml
name: my-app
port: 8080
ratio: 0.75
debug: false
quoted: "value: with a colon"
```

**Comments**, whole-line or trailing:

```yaml
# The port the server binds
port: 8080          # overridden by FLIGHT_SERVER_PORT
```

**`${VAR}` substitution** — see <doc:SecretsAndSubstitution>.

## What is rejected, and what to use instead

| Construct | Why | Instead |
|---|---|---|
| Flow style — `[a, b]`, `{k: v}` | Two syntaxes for one structure; the braces also collide visually with `${VAR}` | Block style |
| Block scalars — `\|`, `>` | Folding rules are subtle and rarely what the author pictured | A quoted string |
| Anchors and aliases — `&x`, `*x` | Indirection in a file whose job is to be read at a glance | Repeat the value |
| Multiple documents — `---` | One file, one configuration | Separate files |
| Tags — `!!str` | Types come from the Swift side | Quote it |

Each rejection names the line and column:

```
flight.yaml:4:3: flow style ('[…]' / '{…}') is not supported by the Flight
YAML subset — quote the value if the character is literal
```

## Robustness

**A UTF-8 BOM is stripped.** Windows editors write one by default, and it is
invisible. Left in place it would become part of the first key — so
`server.port` would parse as `\u{FEFF}server.port` and every lookup for it
would report the key missing, from a file that visibly contains it.

**All three line endings work.** LF, CRLF, and CR all separate lines, so a
file edited on Windows and one edited on Linux parse identically.

**Duplicate keys are rejected**, rather than last-one-winning silently.

## Reading a file yourself

`FlightYAMLDocument` is the parser, usable directly:

```swift
let document = try FlightYAMLDocument(contentsOf: url)
document.keys                       // every flattened key
document.rawValue(for: "server.port")   // "8080"
```

This is also what build tooling uses to check configuration keys at compile
time — it lives in the dependency-free core module for exactly that reason.
