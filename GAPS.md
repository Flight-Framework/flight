# What is missing

An audit of every library in the ecosystem, written 2026-08-24 against the
v0.1.2 tags. Each entry says what is absent, why it matters, and how much work
it looks like — so the list can be argued with rather than just worked
through.

Ordered by consequence, not by library. Entries closed overnight on
2026-08-24/25 are marked ✅ with what actually landed; three entries in the
first draft were **wrong** and are struck rather than deleted, because the
useful thing about a wrong entry is knowing it was wrong.

**Still open, in rough priority order:** flight-web HTTP/2 (now a design
decision, not a task — see below); hangar composite-key associations; the
presence gossip trust model; the scheduler package; npm and Homebrew
publishing; format debt.

**DocC is done** where it makes sense: 17 of flight's 20 targets, 8 of
flight-data's, hangar and swift-changeset. The three flight targets without
catalogues are the two macro implementations and the registration generator,
which have no consumer-facing API.

**Needs a decision from you, not more work:**
- **Tag hangar v0.2.0.** Soft delete, pagination, slow-query diagnostics,
  introspection, `EXPLAIN` and CTEs all landed after 0.1.0. `hangar-vapor`
  cannot be published until that tag exists.
- **Create the `hangar-vapor` repository.** The package is written, tested
  against a real pool in a real Vapor app, and committed locally at
  `Hangar/hangar-vapor` — but creating a public repo under the org is yours
  to do, not mine to assume.

---

## 1. Verification gaps — things CI does not actually check

These come first because everything below is a claim, and a claim CI does not
exercise is a claim nobody has tested since the day it was written.

### ✅ flight-data ran no integration tests *(fixed 2026-08-24)*
Its CI had neither a Postgres nor a Valkey service, so every driver suite
skipped on every push. The drivers are the whole reason the package exists.
Fixed, and the fix immediately surfaced a flaky TTL test that had been passing
only because nobody ran it. The gate itself then failed for a day because it
used bash-only `${!var}` indirect expansion and the Swift image's default
shell for a `run:` step is `sh`. 49 integration tests run in CI now; only the
outage-recovery suite skips, and it has to — it kills and restarts a server,
which a service container cannot do.

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

### ✅ No macOS build anywhere *(fixed 2026-08-25)*
Every package now has a `macos-15` job. The repos are public, so the 10×
private-repo billing note no longer applies.

Two things had to be learned the hard way: `swift-actions/setup-swift` only
indexes up to 6.2, so the packages declaring tools 6.3 install via `swiftly`
instead — which is also what the toolchain is managed with locally, so CI and
a developer's machine now resolve the same way. And the jobs are build-only
except `flight-cli`'s: macOS runners have no Docker and GitHub service
containers are Linux-only, while these integration suites *fail* rather than
skip without a database. There is no honest way to run them there.

hangar's, swift-changeset's and `flight-cli`'s macOS builds are green.
`flight-cli`'s matters most — Homebrew runs on macOS, so that gap is now
unblocked.

**And the job immediately earned its place.** `flight` and `flight-data` do
**not** build on macOS, and the cause is upstream:
`apple/swift-configuration` 1.2.0 — the latest release — calls `Data.bytes`
in `FileProvider.swift`, which exists on the Linux Foundation it was written
against and not on the Darwin one. Nothing in either package can fix it, and
pinning to an unreleased `main` is worse than knowing.

So `platforms: [.macOS(.v15)]` in those two `Package.swift` files is
**false today**. Both jobs are `continue-on-error: true` with the reason
written into the workflow; drop that line the moment upstream ships a fix. A
permanently red required check only teaches people to ignore CI.

*Worth reporting upstream — an outward-facing action, so yours to make.*

---

## 2. Documentation that is wrong or absent

### ✅ `flight/Docs/channels.md` states something untrue *(fixed 2026-08-24)*
> "Security Core is not yet built"

It ships, the demo uses it, and the retroactive `Principal` conformance the
passage predicts is exactly what `Main.swift` now does. A reader takes this as
current.

### ✅ The testing libraries are barely documented *(fixed 2026-08-24)*
`flight/Docs/testing.md` now covers the three sizes of test, and
`Snippets/TestingShapes.swift` compiles every shape it shows — which
immediately caught an `InMemoryCluster(nodes:)` initializer the guide claimed
and that never existed. `FlightWebTesting` also has a DocC catalogue now.

Original entry:

`FlightWebTesting`, `FlightPubSubTesting`, `FlightChannelsTesting`,
`FlightCacheTesting`, `FlightDataTesting` and the new `Components` are each
mentioned in one or two pages in passing. They are what someone reaches for on
day two, and there is no page that says how to test a Flight application.
**Size:** medium. **Highest doc value on the list.**

### ◐ DocC covers 3 of 27 modules — now 13 *(partly closed 2026-08-25)*
Ten new catalogues: `FlightWeb`, `FlightChannels`, `FlightPubSub`,
`FlightActuator`, `FlightSecurityCore`, `FlightWebTesting`,
`FlightTransport`, `FlightDataCore`, `FlightCache`, `FlightDataPostgres` —
plus `HangarVapor`'s README and hangar's existing catalogue.

The more important half: **nothing was building any of them.** Neither
`flight` nor `flight-data` had a docs job at all, so even the three original
catalogues had never been verified. Both now build every catalogue with
`--warnings-as-errors`, which found real breakage on the first run — an
`OIDCTokenValidator` doc comment linking an internal type, a
`DataSourceError` case link that named a case that does not exist, and a
`ClusteredPubSub` initializer documenting two of its five parameters.

It also caught two pages of *mine* that described APIs incorrectly: a
`Channel.join` that took a payload and threw (it does neither), and
`@Cacheable("prices", ttl: .minutes(5))` (the macro takes `namespace:` and
`Duration` has no `.minutes`). Both were rewritten from the source. That is
the argument for the CI job in one paragraph.

Finished the same night: the protocol and client modules, the testing
helpers, presence, and `flight-data`'s Valkey drivers, its testing
datasource and its migration core. Every catalogue is built in CI. What is
left has no consumer-facing API to document.

---

## 3. Declared gaps, by library

### hangar
- ✅ **No CTEs (`WITH … AS`).** *Closed 2026-08-25.* `with`/`withRecursive`
  define them; `reading(from:)` makes one the query's source, rendered as
  `FROM "cte" AS "entity_table"` so every column reference downstream
  resolves unchanged. Non-recursive bodies can be a typed `Query`; recursive
  ones take a typed anchor and a raw step. `count`, `exists`, `delete` and
  `update` all carry the clause; a bulk write may be *fed* by a CTE but is
  refused if it tries to target one.

  Found while wiring it: `Query.rebinding` — the projection pivot — copied
  every clause except `deletedRows`, so `.withDeleted().select {}` quietly
  went back to hiding deleted rows and `.onlyDeleted()` inverted to mean its
  opposite. Fixed and pinned.
- **No composite-key associations.** `@HasMany`/`@BelongsTo` assume a single
  column. *Medium, and nobody has asked.*
- ✅ **No `EXPLAIN` helper.** *Closed 2026-08-24.*

### ✅ swift-changeset *(both closed 2026-08-25)*
- **Nested changesets.** `nest` attaches children under an association name;
  the parent is invalid while any child is, and child errors surface under
  the path a nested form renders against (`lineItems[2].quantity`). It
  deliberately does not write or decide write order — an insert's children
  need the parent's generated key, so `validatedChanges()` and
  `validatedNestedChanges()` are two calls.
- **Optimistic locking.** `optimisticLock(\.version)` puts the incremented
  value in the `SET` and the value read from the original in the `WHERE`, so
  a driver that has never heard of locking emits the right SQL and matches
  zero rows when someone else got there first. `ValidatedChanges.lock` exists
  only so a driver can raise `ChangesetConflictError` instead of reporting a
  bare row count.

### flight-web
- **No HTTP/2 or HTTP/3.** I looked into this properly on 2026-08-25 and the
  original entry — "HummingbirdCore supports HTTP/2 and the transport seam
  would take it" — is **too optimistic**, so it is now a decision rather than
  a task.

  The seam does take it: `ServerTransport` does not care. The problem is one
  layer down. `FlightTransport` builds its server with
  `HTTPServerBuilder.http1WebSocketUpgrade`, and Hummingbird's HTTP/2 entry
  point is `HTTPServerBuilder.http2Upgrade(tlsConfiguration:configuration:)`,
  which constructs a whole `HTTP2UpgradeChannel` from a responder. It takes
  an `HTTP2ChannelConfiguration` and has **no WebSocket upgrade hook**, and
  hummingbird-websocket 2.7.0 has no HTTP/2 integration at all — no RFC 8441
  extended CONNECT.

  So on hummingbird 2.26.0 / hummingbird-websocket 2.7.0, **HTTP/2 and
  WebSockets are mutually exclusive on one listener.** Channels — arguably
  the framework's most distinctive feature — are WebSockets.

  The options, none of which I should pick unattended:
  1. HTTP/2 as an opt-in that disables WebSockets on that listener. Honest,
     documented, and a footgun for anyone who enables it without reading.
  2. Two listeners: HTTP/2 on one port, HTTP/1.1 + WebSockets on another.
     Works today, complicates deployment and the actuator's self-report.
  3. Wait for RFC 8441 support upstream, and ship HTTP/1.1 only until then.

  *Medium once the choice is made; the choice is the hard part.*
- No templating or SSR. *Deliberate; out of scope.*
- No runtime route-registration API beyond the bootstrap escape hatch.
  *Deliberate.*

### flight-actuator
- ~~**No authenticated production access.**~~ **Wrong — struck.** I read a
  stale passage in `Docs/actuator.md` rather than the code. `ActuatorExposure`
  already has three levels, and `health_only` is the *default* outside
  development precisely so an orchestrator has a probe. The doc contradicted
  itself and has been fixed.
  What remains, and it is small: the `full` dashboard is unauthenticated
  wherever it is enabled, so running it in production needs something in
  front. That is now stated in the doc rather than implied. *Small.*
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

### ◐ A Vapor shim for hangar *(written 2026-08-25, not published)*
`hangar-vapor` exists at `Hangar/hangar-vapor`, committed locally: three
pieces and nothing else — `app.hangar.use(config)` owns the pool's lifetime,
`req.hangar` is a `Repo` carrying the request's logger, and
`req.transaction { }` runs on one connection and binds `Repo.current` so a
service type can join without every signature threading a repo through. Nine
integration tests against a real pool in a real application, gated so they
cannot skip; `Snippets/ReadmeShapes.swift` compiles every example the README
shows.

`req.hangar` deliberately does *not* pin a connection for the request's
lifetime — a handler awaiting an HTTP call between two queries should not be
holding one.

**Blocked on two decisions of yours:** a hangar v0.2.0 tag, and creating the
public repository.

### ✅ A contributor test script *(done 2026-08-24/25)*
`./scripts/test.sh` in hangar, flight-data and hangar-vapor: starts throwaway
containers, runs everything through `CI/run-tests.sh`, tears them down.

flight-data's waited for Postgres and then started the suite, leaving Valkey
to race the Swift build. It usually won — which is how a suite becomes
intermittently red for reasons nobody can reproduce. It waits for both now.

### ✅ `flight new --with` flags *(done 2026-08-24)*

---

## 5. Known-and-accepted

Recorded so they are not rediscovered as bugs:

- **Format debt**: `flight` ~1,309 and `flight-data` ~1,094 violations against
  the shared `.swift-format`. Both lint jobs are advisory. `flight-cli` is
  clean and blocking. A bulk reformat must avoid the macro fixture files,
  whose expected-expansion strings a careless regex corrupts.
- **The tutorial checkpoint runner had been red since it landed** — 6 of 9,
  and it took two fixes. All three failures were `curl: command not found`;
  the Swift images carry neither python3 nor curl, and only python3 was
  installed. That took it to 8 of 9. The last one was a real race the
  tutorial teaches: the checkpoint backgrounds `swift run App` and curls it
  on the next line, so a reader copying the block gets connection refused
  while the server is still binding. Now waits on `/actuator/health` with a
  bounded `curl --retry-connrefused`.

  Then cp06 and cp08 broke — one checkpoint poisoning the next. The runner
  cleaned up with `pkill -f "$work"`, which can never match: the server
  appears in `ps` as a relative path with the work directory nowhere in its
  command line. Any checkpoint failing before its `kill %1` left a server
  holding port 8080, and everything after it died on "Address already in
  use". Each block now runs under `setsid` and cleanup kills the process
  group. (I hit this myself — the sabotage run I used to test the cp03 fix
  leaked a server that quietly broke every local run for an hour, which is
  how I found it.)

  All fixed 2026-08-25. Recorded because each failure was misattributed in
  the same way: the first *looked* like "the tutorial is broken" and was
  "the image is thin"; the second looked like CI flakiness and was a defect
  in the documentation; the third looked like three unrelated failures and
  was one leaked process. That is how a useful check gets ignored.

### ✅ A generated app crashed instead of failing to start *(fixed 2026-08-25)*
Found while chasing the above, and worse than the thing I was chasing. When
bootstrap failed, a generated app died with `Fatal error: Error raised at
top level`, a register dump, thread backtraces and a loaded-image list —
because the template's `main` was `async throws` and the Swift runtime traps
on an error that escapes it.

The two failures a first project actually hits are Postgres not running and
port 8080 already bound. Neither is a crash; both were reported as one. All
three templates now catch, print one line, and exit 1 — verified on real
generated projects for both cases.

**Still open:** the same fix belongs in `FlightCore` as a `Flight.main`
helper, so hand-written applications get it too rather than only generated
ones. Blocked on a flight release, since templates pin 0.1.2.
- **One unexplained test failure**, flight-data, 2026-08-25: a single issue
  in a 375-test run that did not reproduce in ten subsequent runs, cold
  containers included. The Valkey readiness gap was fixed because it was
  genuinely there, not because it was shown to be the cause. Recorded so the
  next occurrence is the second one rather than the first.
- **Root builds need `--enable-all-traits`.** A root build compiles every
  target regardless of traits, so a plain `swift build` in `flight` or
  `flight-data` fails by design. Documented in both READMEs.
- **Relative paths remain in git history.** Not sensitive; removing them would
  mean rewriting three more repositories and moving four tags for no security
  benefit.
- **Old per-package repos are archived**, with notices pointing at their
  replacements.
