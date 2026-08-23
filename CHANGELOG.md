# Changelog

All notable changes are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
