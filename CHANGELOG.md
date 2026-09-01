# Changelog

All notable changes are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

First increment of the container → composition migration. See
`COMPOSITION-MIGRATION.md` for the full specification.

### Breaking

- **`@Transactional` is removed**, along with `FlightTransactionCoordinator`,
  `FlightAsyncTransactionCoordinator`, `FlightTransactions` and its
  task-locals, and the `begin/commit/rollbackPreferringAsync` family.
  Transactions belong to the data layer: use Hangar's
  `repo.transaction { tx in … }`, which additionally supports isolation
  levels, savepoint nesting as designed behavior rather than a guess, and
  `retryingOnSerializationFailure:` — none of which the macro could express.

  The macro's boundary was invisible at the call site, and its nesting
  semantics had to infer whether a transaction was already open. That
  inference is the documented cause of a silent data-loss path in Hangar's
  integration (a `Repo` resolved before a transaction opened would emit a
  literal `COMMIT`, ending the enclosing transaction and making writes the
  caller intended to roll back durable). An explicit closure cannot get this
  wrong: the transaction's `Repo` either is used or isn't.

  It was also the last framework-mandated ambient state in Flight.

  Migration: replace `@Transactional func f() throws { body }` with
  `try await repo.transaction { tx in body }`, threading `tx` to helpers that
  participate. Consumers pinning a published `flight` version migrate after
  this ships.

## [0.12.0] - 2026-09-01

### Breaking

- **Flight Actuator's JSON and HTML wire format drops "bean" for
  "component."** The JSON key `"beans"` is now `"components"`; the internal
  `BeanRepresentation` type is `ComponentRepresentation`; the HTML dashboard's
  "Beans" section is "Components." Anything polling `/actuator/*`'s JSON
  output needs to read the new key. `ComponentDescriptor` (Core's own
  introspection type, unchanged) already used "component" — this brings the
  wire format in line with it, and finishes a rename SPIKE-FINDINGS.md
  records as already having been attempted once (2026-07-17, delta 13) but
  which didn't fully take. "Bean" is JavaBeans/Spring vocabulary Flight
  doesn't otherwise use; one exception was left deliberately —
  `FlightActuator.docc/FlightActuator.md`'s "there is no `/actuator/beans`"
  names Spring Boot Actuator's own real endpoint as a contrast, not Flight's
  vocabulary.
- **`@Autowired` is renamed `@Inject`.** Every property injection site across
  every product (`FlightCore`, `FlightWeb`, `FlightScheduler`,
  `FlightSecurityCore`, and any application code) must update. No deprecated
  alias — a straight rename, hard cutover.
- **The route-mapping macros drop the `Mapping` suffix and gain a `Route`
  one:** `@GetMapping` → `@GetRoute`, `@PostMapping` → `@PostRoute`,
  `@PutMapping` → `@PutRoute`, `@PatchMapping` → `@PatchRoute`,
  `@DeleteMapping` → `@DeleteRoute`, `@WebSocketMapping` → `@WebSocketRoute`.
  `@Controller` is unchanged. Both renames exist to stop reading as Spring's
  own naming convention (`@Autowired`, `@GetMapping` are Spring Framework's
  literal names) — Flight's DI and routing are its own design, not a port,
  and the names should say so.

  Internal-only, alongside the public rename: `AutowiredMacro` →
  `InjectMacro`, `RouteMappingMacro` → `RouteMacro` (file renamed to match),
  `MappingKind` → `RouteKind`, and every `autowired.*`/`mapping.*` diagnostic
  ID becomes `inject.*`/`route.*`.

## [0.11.0] - 2026-08-29

The six findings the 0.10.0 audit deliberately left open, closed. Three were
open because the fix looked bigger than it was, two because the cost/benefit
had not been argued, and one because it needed a decision rather than code.

### Breaking

- **`server.idle-timeout-seconds` defaults to 60** (`0` disables). It cannot
  affect a long response — see below.
- **`flight.channels.write-timeout-seconds` defaults to 30** (`0` disables).
- **`security.oidc.allowed_algorithms` defaults to the asymmetric set.** A
  token whose `alg` is outside it is refused; previously only `none` was.
- **`DistributedPubSubAdapter` gains `subscribed(to:)` /
  `unsubscribed(from:)`.** Both have default no-op implementations, so
  existing adapters are unaffected and stay firehose-shaped.

### Added

- **Topic interest on the adapter seam.** The seam carried no subscribe
  signal, so an adapter had to take the whole cluster's firehose — fine at
  small topic counts, a fan-in ceiling at large ones, and unliftable without
  changing the protocol. The callbacks fire on the *first* subscriber to a
  topic and the *last* unsubscribe, which is already the granularity a wire
  subscription wants, so a per-topic adapter needs no debouncing. Firehose
  adapters ignore them and are documented as the right default.
- **A JWT algorithm allowlist.** The RS256→HS256 confusion an allowlist
  normally guards against is unreachable here — verification keys come solely
  from the JWKS and JWTKit's `JWK` has no symmetric type — but that is three
  separate facts staying true rather than one check. The half that earns its
  keep is narrowing to what an IdP actually issues.

### Fixed

- **Connection idle and header-read timeouts** (GAPS.md's slowloris-adjacent
  gap). The entry said `HummingbirdCore.ServerConfiguration` "exposes no knob
  for it at all", which was true of `ServerConfiguration` and wrong about
  Hummingbird: `HTTP1Channel.Configuration.idleTimeout` has one.

  That alone left the purest case open, and why is the interesting part: the
  upgrade channel installs Hummingbird's idle handler from its *not-upgrading
  completion handler*, which does not run until a head has decoded — so a
  connection that never finishes its first header block is invisible to it.
  Flight adds a header-read timeout in front of the channel for that window.
  One setting, two mechanisms.

  Neither can touch a slow *response*: both disarm once a request is fully
  read, so a large download, an SSE stream and an upgraded WebSocket run as
  long as they like. That is what makes a default safe, and there is a wire
  test for each of the four cases.
- **A WebSocket write had no bound.** The heartbeat watchdog counts *inbound*
  frames as liveness, so a client that keeps heartbeating while never reading
  looks alive to it while the writer sits in `send` against a TCP window that
  never opens. Memory stayed bounded by the outbound queue; a task and a
  connection accumulated per such client.
- **Config: an absent key cost up to ten provider calls per layer** — thirty
  on a three-layer stack — because swift-configuration's lookup is
  type-directed and absence has to be established rather than assumed.
  Flight's own providers know their key set outright and now answer in one; a
  third-party provider keeps the type-directed walk, which is correct, just
  slower. Absent keys are not the rare case they sound like: `AdapterPresence`
  probes keys that are *supposed* to be missing, and so does every
  `getIfPresent` for an optional setting.
- **Config: the raw-string→`ConfigValue` conversion was written twice**, as
  two near-identical switches differing only in which error they threw.
  Neither had drifted, which is the moment to merge them rather than the
  moment after. A config file's bytes are also copied in one go now, rather
  than one byte at a time through `unsafeLoad`.

### Changed

- **Presence: the gossip trust model is decided and written down.** The
  boundary is the PubSub bus: anything that can publish to the reserved topic
  can assert presence state, and nothing authenticates a frame — Phoenix
  Presence's posture over Redis, and the right one for a broker inside your
  network. Stated rather than assumed, because the consequence deserves to be
  explicit. Frame authentication was considered and not taken: it moves key
  distribution and rotation onto the operator to defend a boundary the rest of
  the stack does not defend either.

  Within that boundary, buggy peers and version skew are bounded by rules no
  correct sender ever violates — a frame asserting a third replica's entries
  is dropped, and so is one over `flight.presence.max-entries-per-frame`
  (10,000). The rolling-upgrade story is now written down too: a version bump
  partitions presence for the duration of the roll, which beats two versions
  agreeing on the bytes and disagreeing on the meaning.
- **One timeout primitive, `FlightCore.withFlightTimeout`.** Writing the
  WebSocket write bound found a live instance of a trap this codebase had
  already been bitten by once: the first version raced the send in a
  `withThrowingTaskGroup`, and a task group awaits its children at scope exit
  — so a `send` that ignores cancellation hangs despite the timeout. The test
  that proved it hung the suite, which is how it was found. Both this and
  `ClusteredPubSub.broadcast` go through one primitive now, with the reasoning
  written down once rather than in two subtle copies.

1052 tests (was 1028).

## [0.10.1] - 2026-08-29

The last finding from the 0.10.0 audit, which landed after the tag.

### Fixed

- **Only this process's own broadcaster gets the encode-once fast path.**
  The 0.9.0 optimization carries a broadcast's wire frame in message
  metadata, and `SocketSession.pump` forwarded whatever sat under that key
  verbatim — around the reserved-event guard and around valid-envelope
  framing both. Any in-process publisher that stamped `flight.channels.frame`
  could push a `flight:join`, or any other reserved event, to every joined
  socket. It takes application code misusing a reserved key, which is why the
  audit called it misuse-resistance rather than an attack surface; it is
  still a seam that should not exist. Frames now carry a process-wide random
  token and the fast path runs only for a match — the same shape
  `ClusteredPubSub` uses for echo suppression, and for the same reason: a
  guessable name is not a capability. A clustered frame from another node
  carries no token and correctly takes the validating path.

### Documentation

- `Docs/presence.md` claimed duplicated gossip is harmless without
  qualification. It is, except across a permdown purge, which forgets a
  replica's causal context — so a duplicate of a pre-purge add-delta arriving
  more than `permdown-after` late would resurrect an entry until the next
  snapshot repaired it. Theoretical with any sane transport, and worth naming
  as the one hole rather than leaving the claim unbounded.

## [0.10.0] - 2026-08-29

A full source audit — every file under `Sources/`, ten reviewers, one per
product, with `README.md`, the per-product docs and `GAPS.md` as the promise
baseline — ran against 0.9.1. This release works through what it found. Every
high-severity fix has a regression test that fails against the code it
replaces.

Two shapes ran through the findings and are worth naming, because they are
what to look for next time. **Bounds enforced on one path but not its
mirror**: JWKS staleness was checked when a refresh was attempted and not when
cached keys were returned; backpressure was fixed in the request direction in
0.8.0 and not in the response direction. **Features shipped inert** — the
class GAPS.md's own `@Scheduler` postmortem describes — found twice more, both
times behind a seam every test called around.

### Breaking

- **A streaming response producer takes a `ResponseBodyWriter`, not an
  `AsyncStream.Continuation`,** and `ServerSentEventWriter.send` /
  `sendHeartbeat` are `async`. Awaiting is the point: a producer that cannot
  be made to wait cannot be given backpressure. Add `await` at SSE call sites.
- **`Response.streaming`'s producer starts on the transport's first read**
  rather than at response construction.
- **`SchedulerService.resolveCoordinator` throws** for a coordinator that is
  registered but cannot be built.
- **`RouteRegistration(method:)` fails on an unrecognized method string**
  instead of registering the route as GET.
- **An unset `FLIGHT_ENV` no longer publishes the actuator dashboard.**
  Declare `FLIGHT_ENV=dev`, or set `FLIGHT_ACTUATOR_EXPOSURE=full`.
- **`iat` is no longer stripped from `Principal.claims`.**
- Cron: `0 0 0 */2 * MON` — both day fields narrowed with a `*/n` step — is
  refused rather than resolved one of the two ways implementations disagree
  about.

### Fixed

**Scheduler** — the three worst defects in the audit were all here. One
exhausted schedule (`0 0 0 30 2 *` parses fine and never fires) cancelled
*every other job*, against the doc's "one broken job never stops the others".
`OverlapPolicy` was inert: `fire()` was only ever called from its own awaited
loop, so `.skip` never skipped and `.queue`'s documented behaviour did not
exist. And cron could answer with an instant up to an hour *in the past*
during a DST fall-back, so the runner fired, recomputed the same past instant,
and spun until real time left the fold.

Also: an interval job with `.once` cannot be coordinated (its firing instants
are node-local) and now says so at startup; sub-second durations were
truncated to zero; `lastDuration` reported whole seconds; the `timeZone:`
argument was never build-checked, so `"America/NewYork"` ran in GMT silently;
`5-7` in day-of-week was refused as a backwards range.

**Security** — `jwks_max_stale` was enforced only where a refresh was
attempted. Refreshes are cooldown-gated, so past the limit roughly one request
per window was refused while every other one kept validating against keys that
may have been revoked — the guarantee inverted, for the whole outage. Also: a
JWKS whose keys all omit `kid` (legal) was rejected outright, and a kid-less
`use: "enc"` key slipped past the signing-key filter.

**Config** — every provider error was read as "the key is absent here", so a
transient failure in a high-precedence layer fell through and answered from
the layer below: a production key resolved from a development one, silently.
`get(_:default:)` masked a present-but-unreadable value the same way.
Zero-indented block sequences are accepted. Substituted values carry their
secret flag, and `accessReporter` fires for Flight's own accessors.

**Actuator** — the DocC catalogue documented three endpoints that never
existed; the README and manifest advertised metrics that were never written;
and the exposure gate still failed open for a deployment that set nothing.
`/actuator/health/live` and `/actuator/health/ready` answer the two different
questions an orchestrator asks, and `Container.reportHealth(_:forModule:)`
lets a module report what only it knows.

**Web** — response streams had no backpressure at all. A matched request ran
full route-table matching up to four times. A cookie value could forge cookie
attributes. `UpgradeResponse`'s "every transport fails to compile" promise was
defeated by the one transport that exists. A mapping attribute outside
`@Controller` registered nothing and said nothing. Plus: configured coders
bypassed for dictionaries and nil-optional 404s, three tus 1.0 wire
deviations, an asset exclusion evaded by percent-encoding, `gzip;q=0` read as
acceptance, and `Accept: */*` (which is `fetch()`'s own default) treated as a
navigation.

**Channels** — three client lifecycle defects: a duplicate join silently lost
its rejoin intent, `disconnect()` promised a rejoin `connect()` never
performed, and a disconnect racing an in-flight dial resurrected a closed
client. Client streams and channel records grew without limit, where the
server side had bounded both.

**Presence** — a peer frame claiming the receiving replica's own dots was a
one-frame remote process kill. The CRDT merge scanned every entry in the
cluster per gossip frame; it is indexed by replica now.

**PubSub** — `broadcastTimeout` did not bound `publish` against an adapter
that does not respond to cancellation, which the adapter contract never
required it to. The documented buffering and cluster knobs were unreachable
through `FlightPubSubModule`.

**Core** — `resolve` demangled a type name on every scoped and transient
construction, defeating the lazy demangling its own comment justifies.

### Documentation

The README pinned `from: "0.2.1"` in four places, claimed 685 tests across 14
targets, said Swift 6.2+ where the manifest says 6.3, and stated macOS support
without the caveat GAPS.md records. `Docs/web.md` was roughly eight releases
stale and taught a deprecated middleware API as its flagship example. Every
trait guard's comment described the opposite polarity. The DocC CI job was red
on `main` — `FlightWeb`'s catalogue listed six macros under signatures none of
them have — and all 18 catalogues build clean again.

## [0.9.1] - 2026-08-29

### Fixed

- **An empty `container.pipeline("name") { }` now declares its lane.** It
  registered nothing, so the lane left no trace, and any route or asset
  mount naming it failed dispatch validation at bootstrap — with an error
  that itself said "an empty block is legal". `pipeline(_:_:)` registered
  one `MiddlewareRegistration` per middleware in the block, and
  `declaredMiddlewareLanes()` derives the lane set from those entries: no
  middleware, no entries, no lane. It now registers a marker entry per
  named lane ahead of the loop, filtered out of
  `collectMiddleware(lane:)`, so a request through an empty lane still
  runs nothing extra — the marker is bookkeeping, not a layer. The
  qualifier carries a per-call token because two modules may legally
  declare into one lane, and a fixed qualifier made the second call a
  duplicate registration (caught by the existing concatenation test, not
  by review). The empty lane is the shape a static-asset mount wants, so
  a request for `app.js` pays for none of the auth and transaction
  binding the default lane carries — which is how this surfaced.

## [0.9.0] - 2026-08-28

### Added

- **Cookies** — `FlightWeb` had no cookie handling at all: no parsing, no
  `Set-Cookie`, no redirect helper. `Cookie` renders `Set-Cookie` with
  safe defaults (`HttpOnly` and `SameSite=Lax` on unless turned off);
  `request.cookies` / `request.cookie(_:)` parse the request's `Cookie`
  header (splitting on the first `=` so JWT/base64 values survive,
  keeping the first of duplicate names); `response.settingCookie(_:)`
  appends rather than replaces, since several cookies means several
  headers; `Cookie.expiring(_:path:domain:)` for deletion; and
  `Response.seeOther(_:)`, the 303 a form-post login wants. 10 tests,
  including two sabotage checks (replace-instead-of-append silently
  drops a cookie; splitting on the last `=` corrupts values containing
  one).

### Changed

- **Channel broadcast fan-out encodes each frame once, not once per
  subscriber.** Every joined socket's wire frame for one broadcast is
  byte-identical (same topic/event/payload, `ref: nil`), but
  `SocketSession.pump` was decoding and re-encoding it separately for
  every subscriber — at 200 subscribers, 200 redundant decodes plus 200
  redundant re-encodes of the same bytes. `ChannelBroadcaster.publish`
  now encodes the frame once and carries it in message metadata; `pump`
  forwards that precomputed text directly, falling back to the old
  decode/encode path for a publisher that isn't `ChannelBroadcaster`
  (Presence hand-builds its own `Message`). The outbound socket queue now
  carries pre-encoded `String`s rather than `Envelope` values throughout
  (`Socket`, `ChannelSocketHandler`, `SocketSession`), so single-target
  sends (`push`/`sendReply`/`sendError`) also encode exactly once, at
  enqueue time, rather than at write time.

### Fixed

- **`DiskUploadStore.create(_:)` ignored `createFile`'s result.** A
  failure creating the upload's data file (disk full, permission denied)
  would still let the separate sidecar write succeed, leaving an upload
  that records offsets against a `.bin` file that was never created; now
  throws.
- **`FileByteSource.realPath(_:)` used the deprecated `[CChar]`-based
  `String(cString:)`.** Replaced with an explicit null-terminator
  truncation and `String(decoding:as:)`.

## [0.8.0] - 2026-08-26

### Added

- **Resumable uploads (tus 1.0)** — `container.uploads(at:store:)` mounts
  the protocol as five ordinary routes with pipeline-lane support.
  Supports `creation`, `creation-with-upload`, `termination`, and
  `expiration`; a stale append is refused with the true offset rather than
  applied twice. `DiskUploadStore` records only fsynced offsets (enforced
  by construction) and truncates unacknowledged bytes on reopen, so an
  interrupted upload resumes byte-exactly. `UploadStore` is the seam for
  object storage.

### Fixed

- **Streaming request bodies had no backpressure.** The transport fed an
  unbounded `AsyncThrowingStream`, reading large uploads entirely into
  memory while claiming to stream them; body delivery is now pull-based,
  one chunk per consumer demand.

## [0.7.0] - 2026-08-26

### Added

- **`multipart/form-data`** — `request.multipart()` yields parts as
  streams: constant-memory parsing with named limits (parts, header bytes,
  header count, collect caps), strict CRLF and close-delimiter handling,
  filename hardening, and Go's post-CVE caps from day one. Works over
  buffered and streaming bodies alike.
- **Streaming request bodies** — a handler taking `body: RequestBodyStream`
  is recorded as streaming-bodied in the route table; the transport asks
  before reading (like `acceptsUpgrade`) and hands chunks through live,
  cap enforced as bytes arrive. `maxBodyBytes:` on any route mapping
  overrides the global body cap per route.

## [0.6.0] - 2026-08-26

### Added

- **Form bodies.** `application/x-www-form-urlencoded` decodes into the
  same `body:` handler parameters JSON does, via `FormDecoder` — wire
  semantics documented and pinned (last-occurrence-wins scalars,
  every-occurrence arrays, the checkbox rule for absent `Bool`, strict
  escapes and UTF-8, flat bodies only). `WebCoders` gains `formDecoder`.
- **`body: Data` and `body: String`** handler parameters: raw bytes under
  any label; strictly-validated UTF-8 text. Both previously fell into the
  JSON path by accident of `Data: Decodable`.
- **`MediaType`** — an RFC 9110 §8.3 parser shared by everything that asks
  "what is this body?".
- **Strong content-hash validators**: `options.etag = .contentHash` on an
  asset mount serves `sha256-…` ETags (hand-rolled FIPS 180-4, no new
  dependencies) cached by file identity *including ctime* in a bounded LRU
  — so `If-Range` download resumption actually resumes, and validators
  survive redeploys that rewrite mtimes. Plus
  `ContentDescriptor.download(filename:)` for attachment downloads with
  RFC 8187 filename encoding.

### Changed

- **Request bodies are content-negotiated, and a wrong label is now 415.**
  Absent `Content-Type` still decodes as JSON (the documented leniency,
  kept); `application/json` and `+json` suffixes are JSON; urlencoded is
  the form decoder; anything else answers 415 naming both sides. Breaking:
  a JSON body mislabeled `text/plain` used to decode and no longer does.

## [0.5.0] - 2026-08-26

### Added

- **Pipeline lanes** — middleware stacks as a property of the route.
  `container.pipeline("assets") { … }` declares a named lane;
  `@Controller(pipelines: ["assets"])` (or `registerRoute(pipelines:)`)
  opts routes into it, alone or concatenated with
  `MiddlewareRegistration.defaultLane`. Naming none means the default lane
  — every existing route and `pipeline { }` call behaves identically.
  Dispatch now routes first and runs the matched route's chain, precomposed
  per route at build time; 404s run the default lane so logging still sees
  every miss. Referencing an undeclared lane fails at bootstrap, naming the
  route and the lane.
- **Static asset mounts** — `container.assets(at:root:pipelines:_:)` serves
  a directory as a fallback after routing: real routes always win, and the
  mount runs its own lanes (the reason lanes exist — an asset request needs
  no transaction binding). Conditional requests and ranges via
  `serveContent`; Cache-Control by ordered path-glob rules; SPA fallback
  gated on `Accept` with `exclude` prefixes so API 404s stay API-shaped;
  resolve-then-contain path safety with explicit symlink (`.withinRoot`
  default) and dotfile (deny default) policies; precompressed `.br`/`.gz`
  sidecar negotiation with per-variant validators and `Vary`.

## [0.4.0] - 2026-08-26

### Added

- **`Response.file`** — a fourth body shape: a sized ``ByteSource`` plus the
  byte range to send. The transport writes an exact `Content-Length` and
  streams in constant memory; `.streaming` remains the chunked/SSE shape.
- **`serveContent(for:_:)`** — conditional requests and byte ranges over any
  `ByteSource`: `If-None-Match` (list, `*`, weak comparison),
  `If-Modified-Since`, `If-Range` (strong validators only), suffix ranges,
  EOF clamping, `416` with `Content-Range: bytes */size`, correct
  `HEAD`+`Range`. Plus `ContentDescriptor`, `EntityTag`, and public
  `HTTPDate` formatting/parsing.
- **`FileByteSource`** — open-once/fstat-once file serving off the
  cooperative pool, with deterministic descriptor cleanup and loud failure
  when a file is truncated mid-serve. `DataByteSource` covers blobs and
  tests.

### Changed

- **The upgrade seam is generalized for coming protocol kinds**
  (WebTransport, `connect-udp`): `UpgradeResponse` is now an enum
  (`case webSocket(WebSocketUpgrade)`) and `RouteRegistration.Kind.upgrade`
  carries an `UpgradeKind`. A future kind is an additive case that every
  transport must handle *at compile time*. `ConnectionUpgradeHandler` and
  `UpgradedConnection` are now `WebSocketUpgradeHandler` and
  `WebSocketConnection` — deprecated typealiases keep old spellings
  compiling. Nothing above the seam changed: Channels and raw
  `@WebSocketMapping` handlers are source-identical.

## [0.3.1] - 2026-08-26

### Fixed

- **`@Middleware` and `@Settings` beans never appeared on the actuator
  dashboard.** Adding the two stereotypes updated their labels but not the
  separate, hardcoded section-order list the HTML renderer actually
  iterates — a bean whose stereotype isn't in that list renders nowhere,
  rather than falling back to a generic section. `Stereotype` is now
  `CaseIterable`, and a test checks `allCases` against the section list
  directly so a future stereotype can't repeat this.

## [0.3.0] - 2026-08-26

### Added

- **`@Middleware`**, a stereotype for middleware layers, scanned and
  registered exactly like `@Component`. A type gets its dependencies through
  its initializer like any other component, is independently resolvable and
  testable, and conforms to `Middleware` — `func handle(_ context:
  RequestContext, next: Next) async throws -> Response`.
- **`container.pipeline { }`**, the one place middleware order is declared —
  outermost first, top to bottom. Calling it more than once composes: a
  framework module can install its own middleware ahead of whatever the
  application declares in its own call. A `@Middleware` type listed nowhere
  simply never runs.
- **`Middleware` is now a protocol; `Next` drops `inout`.** `Next` is
  `@Sendable (RequestContext) async throws -> Response` — a plain value in,
  a value out, throwing. Per-request state that must reach downstream layers
  goes through `context.scope`, not context mutation.

### Changed

- Flight Security's authentication middleware is now `Authentication`, a
  `@Middleware` type with `@Autowired var validator: (any TokenValidator)`,
  replacing two near-identical closure-returning functions that existed
  solely because a closure could not hold a dependency. A missing validator
  is now a construction-time failure (caught at `freeze()`), not a
  per-request 500. `requireAuthentication` is now `RequireAuthentication`,
  a `@Middleware` type with the same behavior.

### Deprecated

- `container.registerMiddleware` (both closure forms) and
  `MiddlewareResult` still work, retyped against `ClosureMiddleware`/
  `ClosureNext` — the pre-`@Middleware` `inout` shape. Existing inline
  closures at call sites keep compiling unchanged. Conform a type to
  `Middleware` and list it in `container.pipeline { }` instead.

## [0.2.4] - 2026-08-26

### Added

- **`@Settings`**, a macro for typed configuration bound once, at bootstrap.
  Every stored property becomes a binding under
  `namespace.<kebab-cased-property-name>`; a property with its own default
  is optional, one without is required and checked against `flight.yaml`'s
  base layer at compile time, the same guarantee `@ConfigValue`'s no-default
  form already had. A declared `validate()` runs once, right after
  construction. Registers like any other component — resolve it with
  `@Autowired` anywhere.
- **`@Secret`**, marking a `@Settings` property that must not appear in logs.
  Generates a redacting `CustomStringConvertible` when at least one field
  needs it.
- **`Duration: ConfigDecodable`**, requiring an explicit unit (`"500ms"`,
  `"30s"`, `"12h"`) — a bare number does not guess what unit was meant.
- **`ConfigKeyNaming`** in `FlightConfigCore`: the camelCase → kebab-case
  transform `@Settings` uses, shared between the macro and the build-time
  scanner rather than duplicated.

## [0.2.1] - 2026-08-25

### Fixed

- **`@Scheduler` types were never registered, so scheduled jobs never ran.**
  The macro generated its `_flightRegister` thunk and the runtime was correct,
  but the build plugin's list of registrable attributes did not include
  `Scheduler` — so nothing ever called the thunk. `FlightScheduler` was inert
  in 0.2.0: an application would log `scheduler started with no jobs` and
  otherwise behave normally.

  Every scheduler test called `_flightRegister` by hand, which is exactly the
  step the bug skips, so the whole suite passed. The regression test now reads
  both sides out of the sources — every macro whose expansion emits a
  `_flightRegister` thunk must appear in the generator's list — rather than
  restating a list that would have been copied from the same wrong one.

  Anyone on 0.2.0 using `@Scheduler` should upgrade; nothing else in 0.2.0 is
  affected.

## [0.2.0] - 2026-08-25

### Added

- **`FlightScheduler` — cron and interval jobs as annotated methods.**

  ```swift
  @Scheduler
  struct ReportJobs {
      @Autowired var reports: ReportService

      @Scheduled("0 0 3 * * *")
      func nightlyRollup() async throws { try await reports.rollUpYesterday() }

      @Scheduled(every: .minutes(5), onEveryNode: true)
      func refreshCache() async { await reports.warmCache() }
  }
  ```

  The schedule is checked **by the build**: `@Scheduled("0 0 25 * * *")`
  fails to compile, naming the hour field and its range. That is only worth
  trusting if the build and the runtime agree about the grammar, so the cron
  engine ships as `FlightCronCore` — a dependency-free target the macro
  plugin and the scheduler both import. There is no second parser to drift.

  Six fields, seconds first, with the classic five-field crontab shape
  accepted as the same schedule at second zero. `?`, `L`, `W`, `#` and
  `@daily`-style nicknames are refused rather than guessed at: implementations
  disagree about what they mean, and a schedule that quietly means something
  other than its author intended is worse than one that fails to parse.

  Daylight saving is handled and pinned by tests. A job in the hour that does
  not exist on the spring-forward day runs once, late; a job in the hour that
  happens twice on the fall-back day runs once. The first case caught a real
  bug during development — the search normalized its own state through
  `Calendar`, which resolved the missing hour mid-search and skipped the day
  entirely.

- **Running once, without cluster vocabulary.** `@Scheduled("0 0 3 * * *")`
  runs once — which reads the same whether a deployment has one server or
  five, and is the safe default either way. `onEveryNode: true` is the opt-in
  for work that is per-process by nature. On several servers `once` needs a
  `JobCoordinator`; if none is registered the scheduler says so loudly at
  startup rather than silently running every job everywhere, the same
  discipline `PresenceMode` follows.

  `LocalJobCoordinator` is not a stub — on a single process it is the correct
  implementation — but no distributed coordinator ships yet, and the
  documentation says so plainly rather than implying otherwise.

- **`FlightSchedulerTesting`** — an injectable clock that jumps straight to
  each instant, so scheduler tests run a year of firings in microseconds
  instead of sleeping, and `StubJobCoordinator.refusing` for the
  "another process took this firing" path that is otherwise reachable only by
  running two servers.

- **`SchedulerStatus`**, a resolvable component carrying last firing, last
  outcome, next firing and run/failure counts. Deliberately not an actuator
  endpoint: the actuator collects what it shows through generic container
  introspection, and adding one there would make every application that wants
  `/actuator/health` link the scheduler.

- **`Duration.minutes`, `.hours`, `.days`.** The standard library stops at
  seconds. `days` is 24 hours exactly and says so — across a daylight-saving
  change a civil day is 23 or 25 hours, which is what cron expressions are
  for.

- **DocC catalogues for fifteen more modules**, and a CI job that builds every
  one with `--warnings-as-errors`. Neither this package nor flight-data had a
  docs job at all, so even the two existing catalogues had never been
  verified. Turning the check on immediately found broken symbol links in
  shipped doc comments and an initializer documenting two of its five
  parameters.

- **A macOS build job.** Every package declares `platforms: [.macOS(.v15)]`
  and nothing had ever compiled there.

### Changed

- **Targets are grouped into family directories.** `Sources/` held twenty
  siblings with no structure; it is now eight families — Core, Config, Web,
  Channels, Presence, PubSub, Actuator, Security — mirrored in `Tests/`.
  Product names are unchanged, so this is invisible to consumers.

### Fixed

- **`FlightPubSub`'s documentation claimed a Valkey adapter exists.** It does
  not, in flight-data or anywhere else. `DistributedPubSubAdapter` is an
  unimplemented seam and `InMemoryCluster` is the only conforming type,
  written to test the clustered paths rather than run them. Both the
  catalogue and `ClusteredPubSub`'s initializer now say so.
- **`Docs/channels.md` said Security Core was not built.** It ships, and the
  demo uses it.
- **`Docs/actuator.md` contradicted itself about production access.**
- Two tests located files by deleting a fixed number of path components from
  `#filePath`, which silently resolved to the wrong directory once targets
  moved. Both now walk up to the directory containing `Package.swift`.

### Known issues

- **This package does not build on macOS.** `apple/swift-configuration`
  1.2.0 — the latest release — calls `Data.bytes` in `FileProvider.swift`,
  which exists on the Linux Foundation it was written against and not on the
  Darwin one. Tracked upstream as apple/swift-configuration#178 and
  swiftlang/swift#87196, where it is described as an SDK gap on Apple's own
  CI. Nothing here can fix it; the macOS job is advisory until upstream ships
  a fix.

## [0.1.2] - 2026-08-24

### Security

- **The container no longer vends data races.** `Container.register` and both
  `resolve` overloads now require `T: Sendable`. Previously neither
  constrained `T`, storage was `@unchecked Sendable`, and `resolve` was
  `nonisolated` and synchronous — so two actors could resolve and mutate the
  same non-`Sendable` singleton with **zero compiler diagnostics**, in a
  package whose stated selling point is strict-concurrency correctness. The
  hole was confirmed under ThreadSanitizer before the fix and is a compile
  error after it. The blast radius across all ten dependent packages was two
  forwarding methods.

### Changed

- **`bootstrap`, `assemble`, and `resolveModuleOrder` are now
  `Flight.bootstrap`, `Flight.assemble`, and `Flight.resolveModuleOrder`.**
  They were free functions, injected into the global scope of every module
  that imports this one. Those are useful names and a foundation package has
  no business claiming them.
- **A duplicate registration throws instead of trapping.** A generated
  existential bridge can collide with a hand-written registration, which is a
  wiring problem to report — not a reason to abort the process from inside a
  call the developer did not write. Reported by `freeze()` as
  `BootstrapError.duplicateRegistration`.
- `AssembledApplication` and `AssembledService` conform to `Sendable`.
- `ModuleHealth` conforms to `Equatable`, comparing failures by message.

### Fixed

- **`@Transactional` rollback no longer runs on a cancelled task.** When a
  transaction body threw `CancellationError` — a client disconnecting, a
  shutdown — the rollback was dispatched into an already-cancelled task, so a
  coordinator performing real I/O had that I/O fail immediately and the
  transaction was left open, silently, because rollback is non-throwing.
  Rollback now runs detached and is awaited, so the guarantee still holds on
  return.
- **A failed `freeze()` no longer leaves the container wedged.** It stayed in
  the freezing phase forever: `isFrozen` reported `false` while `resolve`
  happily handed out partially-constructed singletons. There is now a terminal
  failed state that refuses both.
- **Resolution no longer demangles a type name on every call.**
  `ComponentKey` eagerly computed `String(reflecting:)`, which dominated
  `resolve` — a per-request operation — to produce a diagnostic string almost
  never emitted. It is computed on demand now.

### Added

- 12 end-to-end tests for `flight-registration-gen`, which had **none**. It is
  626 lines of build-critical logic whose only prior validation was a demo app
  exercising one happy path with zero existential bridges — so bridge
  synthesis, its most intricate code, had never been executed by anything.
  Coverage now includes bridge synthesis, ambiguity, cycle detection, missing
  registrations, the hand-registered escape hatch, determinism, and malformed
  input.
- DocC catalog with two guides: lifetimes, and compile-time wiring.
- LICENSE, CI, CONTRIBUTING, CHANGELOG.

### Removed

- The `spikes/` directory is no longer tracked — a nested SwiftPM package and
  45 MB of build output that would have shipped in a public repository.

### Documentation

- All internal design-document references removed from source, tests, and
  README, including ones in test names that appear in CI output.
- README rewritten for an external reader; it was a project changelog.
- Sources formatted with `swift-format` against a checked-in `.swift-format`.
