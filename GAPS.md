# What is missing

An audit of every library in the ecosystem, written 2026-08-24 against the
v0.1.2 tags. Each entry says what is absent, why it matters, and how much work
it looks like — so the list can be argued with rather than just worked
through.

Ordered by consequence, not by library.

---

## 1. Verification gaps — things CI does not actually check

These come first because everything below is a claim, and a claim CI does not
exercise is a claim nobody has tested since the day it was written.

### ✅ flight-data ran no integration tests *(fixed 2026-08-24)*
Its CI had neither a Postgres nor a Valkey service, so every driver suite
skipped on every push. The drivers are the whole reason the package exists.
Fixed, and the fix immediately surfaced a flaky TTL test that had been passing
only because nobody ran it.

### ✅ hangar's CI was two releases stale *(fixed 2026-08-24)*
It still checked `swift-changeset` out as a sibling for a path dependency that
became a URL at v0.1.0, floated on `setup-swift`'s minor version, and passed
`-warnings-as-errors` into dependency compilation. Also 13 macro-fixture tests
were failing and invisible — see below.

### ✅ XCTest failures were hidden behind a green summary *(fixed 2026-08-24)*
`swift test` exits non-zero for either testing library, but its *output* does
not say so in one place: swift-testing prints "Test run with N tests" last,
XCTest prints "Executed N tests, with M failures" earlier. Grepping for the
former hid 13 broken fixtures. `hangar/CI/run-tests.sh` now reports both.
**The same pattern should be applied to `flight` and `flight-data`**, which
still grep for one summary.

### ~~`flight` has no integration tests at all~~ — wrong, struck
I claimed this without checking and it is false. `FlightTransportTests` binds
real ports: `HTTPWireTests`, `TLSWireTests` and `WebSocketWireTests` connect
over TCP with a raw socket client, including a TLS handshake against a
per-run self-signed certificate. 27 tests, ungated, running in CI today.

Left visible rather than deleted, because three of my claims in this audit's
first draft were about test coverage and two of them were wrong. Check before
believing an entry here.

### No macOS build anywhere
All CI is `ubuntu-latest`, while every package declares `platforms: [.macOS(.v15)]`.
Nothing has ever compiled on macOS. This blocks the Homebrew work and means
the platform claim is untested.
**Size:** small (one job). **Note:** macOS runners bill at 10× on private
repos, so this is cheap only once the repos are public.

---

## 2. Documentation that is wrong or absent

### `flight/Docs/channels.md` states something untrue
> "Security Core is not yet built"

It ships, the demo uses it, and the retroactive `Principal` conformance the
passage predicts is exactly what `Main.swift` now does. A reader takes this as
current.
**Size:** trivial. **Do it first** — a wrong doc is worse than a missing one.

### The testing libraries are barely documented
`FlightWebTesting`, `FlightPubSubTesting`, `FlightChannelsTesting`,
`FlightCacheTesting`, `FlightDataTesting` and the new `Components` are each
mentioned in one or two pages in passing. They are what someone reaches for on
day two, and there is no page that says how to test a Flight application.
**Size:** medium. **Highest doc value on the list.**

### DocC covers 3 of 27 modules
`FlightCore`, `FlightConfig`, `FlightMigrate` have catalogues. Nothing else
does. The prose in `Docs/` is good; the API reference is mostly absent.
**Size:** large. **Value:** moderate — prose is doing most of the work today.

---

## 3. Declared gaps, by library

### hangar
- **No CTEs (`WITH … AS`).** The last query-shape gap; recursive queries and
  complex reporting need the raw-SQL hatch. *Medium.*
- **No composite-key associations.** `@HasMany`/`@BelongsTo` assume a single
  column. *Medium, and nobody has asked.*
- **No `EXPLAIN` helper.** The diagnostics added today say which query is slow;
  they cannot say why. *Small, and pairs naturally with what is there.*

### swift-changeset
- **No nested or embedded changesets** — validating a parent and its children
  as one unit. Its README names this. Ecto has it and people use it. *Large.*
- **No optimistic locking.** Also named. *Small.*

### flight-web
- No HTTP/2 or HTTP/3 — HummingbirdCore supports HTTP/2 and the transport seam
  would take it. *Medium.*
- No templating or SSR. *Deliberate; out of scope.*
- No runtime route-registration API beyond the bootstrap escape hatch.
  *Deliberate.*

### flight-actuator
- **No authenticated production access.** In `.prod` the routes are simply not
  registered. The seam for exposing them behind Security exists and was never
  built, so a team wanting health checks in production has no path. *Medium,
  and the most likely thing a real deployment asks for.*
- No live-updating dashboard, no historical metrics. *Deliberate.*

### flight-presence
- **The gossip trust model.** Deferred by agreement, still open: what happens
  when a malicious or buggy node gossips bad state, and what the rolling-upgrade
  story is across protocol versions. *Large, and needs a threat-model decision
  before any code.*

### flight-data / drivers
- No cross-database abstraction, no auto-migration at boot, no query caching.
  *All deliberate.*
- `FlightDataValkey` has no PubSub and no `@Transactional`. *Deliberate — Valkey
  is not transactional in that sense.*

### flight-channels-js
- Published to a repo, **not to npm**. Blocked on the org being public.
- No CI badge, no bundled build; consumers use it as ESM source. *Fine for now.*

---

## 4. Product gaps — things that would decide adoption

### A Vapor shim for hangar
Hangar has zero Flight coupling and `Repo(client:)` is the whole entry point,
so a Vapor app can use it today. What is missing is packaging and proof: a
`req.hangar` accessor with request-scoped connection handling, and a page
saying "keep Vapor and Fluent, use Hangar for the query Fluent cannot express."
**Nobody switches frameworks for an ORM; plenty would add a library.**
*Small-to-medium, high leverage.*

### A contributor test script
"You need Postgres" is a paragraph in CONTRIBUTING. It should be
`./scripts/test.sh` — start a throwaway container, run the suite, tear it down.
*Small.*

### `flight new --with` flags
The CLI takes `--tier` only. Trait selection (`--with postgres,valkey,security`)
is implied by the tier today, which is fine until someone wants Valkey in a
`basics` project.
*Small.*

---

## 5. Known-and-accepted

Recorded so they are not rediscovered as bugs:

- **Format debt**: `flight` ~1,309 and `flight-data` ~1,094 violations against
  the shared `.swift-format`. Both lint jobs are advisory. `flight-cli` is
  clean and blocking. A bulk reformat must avoid the macro fixture files,
  whose expected-expansion strings a careless regex corrupts.
- **Root builds need `--enable-all-traits`.** A root build compiles every
  target regardless of traits, so a plain `swift build` in `flight` or
  `flight-data` fails by design. Documented in both READMEs.
- **Relative paths remain in git history.** Not sensitive; removing them would
  mean rewriting three more repositories and moving four tags for no security
  benefit.
- **Old per-package repos are archived**, with notices pointing at their
  replacements.
