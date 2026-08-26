# Changelog

All notable changes are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
