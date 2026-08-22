# Expected results — BuildPluginSpike

Predictions written *before* running, so the spike can actually falsify them.
Research basis for each is in the repo root `SPIKE-FINDINGS.md`.

## (a) Cross-target source visibility

**Prediction: WORKS.** App's probe reads `Sources/ModuleA/AlphaService.swift`
and finds the `@Component` marker. The plugin enumerates dependency sources
through the SE-0325 package graph (`target.recursiveTargetDependencies` →
`sourceModule.sourceFiles`), and the sandbox permits reading them.

Report line to expect:

    (a) READ OK  dependency source .../Sources/ModuleA/AlphaService.swift — marker FOUND

## (b) Sandbox restrictions

**Predictions:**
- Read of `/etc/hosts`: **permitted** (sandbox profile allows file reads
  broadly; it restricts *writes* and network).
- Write to the package root (`spike-escape-attempt.txt`): **denied**
  (writes are confined to the plugin work directory / temp).
- Write of `SpikeGenerated.swift` into the work directory: **succeeds**
  (that's the supported output channel; App printing the report proves it).

## (c) Dependency target's *generated* output visibility

**Prediction: NOT visible / not guaranteed.** Each target's plugin invocation
gets its own work directory; ModuleA's generated `SpikeGenerated.swift` is
compiled into ModuleA but its path is not part of App's plugin contract, and
no ordering of plugin *command planning* across targets is promised.

Report line to expect:

    (c) sibling generated output NOT visible at ... (expected — per-target work dirs)

Consequence for Flight if confirmed: per-target `_registerAll` functions that
textually include dependency generated files are off the table; aggregation
must come from scanning dependency *sources* in the app target's single
generator run (which is what `FlightRegistrationPlugin` ships doing) — or
from calling dependency `_registerAll` symbols (fine, since those are compiled
into the dependency *module*, visible through normal imports).

## Symbol graph contrast

**Prediction:** `swift package spike-symbolgraph` **succeeds** and prints a
directory containing `*.symbols.json` per target — demonstrating the
capability exists, in the plugin kind Flight can't use for per-build codegen.
`SpikeBuildPlugin` has no `packageManager` property at all (compile-time
absence, not a runtime denial).

## If reality disagrees

Whichever line differs, paste the actual output into SPIKE-FINDINGS.md next
to the prediction and re-derive: (a) failing kills source scanning → fall back
to per-module explicit `configure` registration; (b) tighter than predicted →
generator may need to move to a prebuild command; (c) *succeeding* would
reopen per-target generation as an optimization, nothing more.
