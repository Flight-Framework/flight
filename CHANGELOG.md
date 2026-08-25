# Changelog

All notable changes are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
