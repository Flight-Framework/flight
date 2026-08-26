# What is missing

An audit of every library in the ecosystem, written 2026-08-24 against the
v0.1.2 tags. Each entry says what is absent, why it matters, and how much work
it looks like — so the list can be argued with rather than just worked
through.

Ordered by consequence, not by library. It lives here, in the flagship
repository, because it covers the whole ecosystem — `flight`, `flight-data`,
`hangar`, `swift-changeset`, `flight-cli` and the JS client. It was written
in `flight-cli` only because that happened to be the working directory the
day it was started; its history moved with it. Entries closed overnight on
2026-08-24/25 are marked ✅ with what actually landed; three entries in the
first draft were **wrong** and are struck rather than deleted, because the
useful thing about a wrong entry is knowing it was wrong.

**Still open, in rough priority order:** a distributed PubSub adapter — the
single highest-value gap, because `DistributedPubSubAdapter` has no
implementation and three documented features rest on it (Channels broadcast
across nodes, Presence's membership mode, `ClusteredPubSub` itself); the
three-way duplication of macro injection scanning; flight-web HTTP/2 (a design
decision, not a task — see below); hangar composite-key associations; the
presence gossip trust model; npm and Homebrew publishing; format debt.

**Closed since this was written:** the scheduler (flight 0.2.0/0.2.1, with the
Postgres coordinator in flight-data 0.2.0 and a tutorial stage), the target
regrouping, DocC coverage and its CI jobs, and the macOS jobs.

**DocC is done** where it makes sense: 17 of flight's 20 targets, 8 of
flight-data's, hangar and swift-changeset. The three flight targets without
catalogues are the two macro implementations and the registration generator,
which have no consumer-facing API.

**Both former decisions are done:** hangar v0.2.0 is tagged and
`hangar-vapor` is published. Released since: flight 0.2.0 and 0.2.1,
flight-data 0.2.0, hangar 0.2.0, swift-changeset (nested changesets and
optimistic locking, untagged).

### ⚠ A feature shipped inert, and every check passed
`@Scheduler` went out in flight 0.2.0 with 743 passing tests, a DocC
catalogue, a prose guide and compiled snippets — and did nothing. The build
plugin's `registrableAttributes` did not list `Scheduler`, so the macro's
`_flightRegister` thunk was never called and jobs never ran.

Nothing caught it because every scheduler test called `_flightRegister` by
hand, which is exactly the step the bug skips. What caught it was *booting the
demo*, which printed `scheduler started with no jobs`.

Fixed in 0.2.1. The regression test reads both sides out of the sources —
every macro emitting a registration thunk must appear in the generator's list
— so it also covers the next registering macro somebody adds. Recorded here
because the lesson generalises: a suite, a docs build and compiled snippets
can all pass *above* the layer that is broken, and the tutorial was the only
artifact exercising the real path end to end.

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
- **No connection idle/read timeout — a half-open connection is held
  indefinitely.** Found on 2026-08-26 while building the resumable-upload
  acceptance test: a client that sends request headers with a large
  `Content-Length` and then stops (or vanishes without a FIN) keeps its
  connection and its server-side request alive for **~4 minutes** in
  testing, and `HummingbirdCore.ServerConfiguration` exposes no knob for
  it at all — its initializer takes only address, serverName, backlog,
  reuseAddress, and an availableConnectionsDelegate. That is
  slowloris-adjacent: cheap for a client, expensive for the server, and
  currently unconfigurable from Flight. It also means a resumable upload
  interrupted *mid-request* (rather than between chunk requests) holds its
  per-upload lock until that timeout expires, so a client resuming sooner
  gets 423 rather than a fresh offset — correct, but slower to recover
  than it should be. Another concrete argument for the second transport
  discussed above; a NIO-native or swift-http-server transport would make
  this a configuration line.
- **No HTTP/2 or HTTP/3.** Re-investigated 2026-08-26, and the 08-25 entry
  below needed a correction: it implied the constraint ran deeper than it
  does. What is true on hummingbird 2.26.0 / hummingbird-websocket 2.7.0:
  **HTTP/2 and WebSockets are mutually exclusive on one listener** —
  `HTTPServerBuilder.http2Upgrade` has no WebSocket hook and
  hummingbird-websocket has no RFC 8441 extended CONNECT. Channels are
  WebSockets, so Flight ships HTTP/1.1.

  The correction: **this is Hummingbird's wiring, not the protocol layer's
  capability.** apple/swift-nio-http2 has had RFC 8441 since 1.33.0
  (July 2024, PR #441) — `SETTINGS_ENABLE_CONNECT_PROTOCOL`, the 1→0
  transition rule, `:protocol` pseudo-header validation with the RFC quoted
  inline — and swift-nio-extras converts `:protocol` to swift-http-types'
  `extendedConnectProtocol`. Its issue #92 ("Support extended CONNECT") is
  open only because nobody closed it. Zero Swift server frameworks consume
  the support; the parts are on the shelf, unassembled. Hummingbird's own
  issue (hummingbird-websocket #99, 2025-03) is a maintainer "not possible
  at the moment... I haven't looked into it in any detail", untouched since.

  The landscape moved in mid-2026 and changes the calculus:
  - The Swift **Networking Workgroup** (announced 2026-06) now has Apple,
    Vapor, and Hummingbird converging on `swift-server/swift-http-server`
    (0.1.0, 2026-07): one server with HTTP/1.1 + HTTP/2 + HTTP/3 behind a
    `supportedHTTPVersions` config and an `HTTP3` package trait. Vapor has
    publicly committed to it for H3. Its WebSocket story is in design
    (issue #100) — extended CONNECT is being generalized from
    CONNECT-UDP/datagrams first, WebSockets named as the follow-on.
  - Apple shipped a **pure-Swift QUIC + HTTP/3 stack for Linux**
    (swift-nio-quic / swift-nio-http3, 0.2.x). Not usable yet: prerelease,
    all-SPI ("no support guarantees"), requires a beta swift-crypto env var,
    no mTLS or keylog, and absent from the QUIC Interop Runner — four
    independent not-ready signals. Terminate HTTP/3 at a proxy (Caddy/nginx)
    until those clear; revisit in two quarters.

  The plan, decided 2026-08-26:
  1. **0.4.0 generalized the upgrade seam** (`UpgradeResponse` is a
     discriminated enum, `RouteRegistration.Kind.upgrade(UpgradeKind)`), so
     an HTTP/2 transport serves every existing WebSocket handler unmodified
     — RFC 6455 vs RFC 8441 differ only below `WebSocketConnection` — and
     WebTransport lands later as an additive case, not an API break.
  2. When transport work starts, it is a **second** transport behind
     `ServerTransport` (the seam exists for exactly this), either adopting
     swift-http-server early — the leaning, since that is where the
     ecosystem is converging and Flight has the concrete WebSocket need to
     push its design — or ~1,000 lines of direct NIO wiring over
     NIOHTTP1/NIOHTTP2/NIOWebSocket, which would make Flight the first
     Swift framework serving WebSockets over HTTP/2.
  3. Prerequisite before investing: verify RFC 8441 *client* support in
     practice (Safari and common intermediaries especially). If browsers
     mostly fall back to HTTP/1.1, this drops in priority regardless.

  *The seam work is done; the transport is a bounded project awaiting the
  client-support check and the swift-http-server WebSocket design.*
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

  Then cp06 and cp08 showed red — and they had **never** been passing
  legitimately. The application reads its database URL from `flight.yaml`
  (`127.0.0.1:55432`, hardcoded in the tutorial on purpose so a starter
  project does not fight a local 5432); CI's Postgres is a service container
  elsewhere. The runner rewrote `$FLIGHT_DATABASE_URL`, which is the
  *migrate CLI's* variable and one the application never reads — a split the
  tutorial documents and the runner did not honour.

  So the app died on connection refused every run. Those checkpoints looked
  green because their curls were racing a socket that exists for a few
  milliseconds: the transport binds 8080 and logs "listening" *before* the
  pool gives up, so an immediate request sometimes landed. Adding the health
  check removed the race, and the pre-existing failure became visible —
  which is what a health check is for. The runner now rewrites both sources.

  Fixed along the way, though it turned out **not** to be the cause of the
  above: cleanup used `pkill -f "$work"`, which can never match, because the
  server appears in `ps` as a relative path with the work directory nowhere
  in its command line. Any checkpoint failing before its `kill %1` leaked a
  server holding port 8080. I hit that myself — the sabotage run I used to
  test the cp03 fix leaked a server that broke every local run for an hour.
  Blocks now run under `setsid` and cleanup kills the process group.

  All fixed 2026-08-25; 9 of 9 pass. Recorded because every one of these was
  misattributed on first read: the first *looked* like "the tutorial is
  broken" and was "the image is thin"; the second looked like CI flakiness
  and was a defect in the documentation; the third looked like a leaked
  process and was a config source nobody was patching. I guessed wrong twice
  on that last one before the crash fix below made the app say what was
  actually wrong.

### ✅ A generated app crashed instead of failing to start *(fixed 2026-08-25)*
Found while chasing the above, worse than the thing I was chasing, and the
reason the thing I was chasing became solvable — two rounds went to guessing
because the app's only output was a register dump. When
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
- **A bound transaction scope pins a connection for the scope's whole life.**
  `withPostgresTransactions(in:)` resolves the scope's `Repo` eagerly, to bind
  Hangar's ambient repo, and resolving a `Repo` checks a connection out of the
  pool. For an ordinary request that is the intended model — a request holds a
  connection while it runs. For a **WebSocket upgrade it is a leak**: an
  upgraded request's `Scope` lives as long as the socket, so every open
  browser tab holds a Postgres connection until it closes, and a pool of ten
  serves ten tabs and then nothing.

  Found dogfooding, 2026-08-25, as `PostgresConnection deinitialized before
  being closed` at the end of a test run — a message about a connection rather
  than about the scope that never let go of it.

  The application-level answer, which Flightdeck now uses, is not to bind
  transactions on upgrade requests: the socket path opens its own short scopes
  per membership check. That is correct for the application and does not close
  the gap, because nothing warns an application that does bind them.

  The real fix is making the ambient-repo binding lazy, so a scope that never
  queries never checks a connection out. It needs a Hangar change —
  `Repo.with` takes a concrete `Repo` — and is worth doing: it would also make
  the `.waiting` acquisition unnecessary for request handlers that only
  sometimes touch the database.
- **Flight Web has no static-file handling.** An application that ships a
  browser interface — a single-page application, or just a favicon — has to
  write its own, and the hazards are the usual ones: a path that escapes the
  root, a directory read as a file, content types, and caching rules that
  differ between a content-hashed asset and the shell that names it.

  Flightdeck wrote about a hundred lines to do it, and the first version had a
  live traversal bug that only a test with six spellings of `..` caught. That
  is a bad thing for every application to write once each.

  What belongs in FlightWeb: `Response.file(at:)` plus a
  `container.registerStaticFiles(root:at:)` covering the same ground — resolve
  the path and compare against the root rather than pattern-matching for `..`,
  refuse directories, map extensions to content types, `no-cache` for the
  entry document and `immutable` for hashed assets, and a fall-through mode
  for client-side routing. Range requests and ETags are the obvious next
  layer and not needed for a first version.

  Flightdeck's `WebAppController` is a working reference, tests included.
