# ``FlightScheduler``

Cron and interval jobs as annotated methods, with the schedule checked at
build time.

## Overview

A scheduled job is a method on a component, not an entry in a config file
and not a closure registered during startup:

```swift
@Scheduler
struct ReportJobs {
    @Inject var reports: ReportService

    @Scheduled("0 0 3 * * *")
    func nightlyRollup() async throws {
        try await reports.rollUpYesterday()
    }

    @Scheduled(every: .minutes(5), onEveryNode: true)
    func refreshCache() async throws {
        await reports.warmCache()
    }
}
```

Nothing registers this by hand — the build plugin finds the type, exactly as
it finds a `@Controller`. And because a scheduled job is an ordinary method
on an ordinary component, testing it needs no scheduler at all: construct the
type with a stub service and call the method.

## The schedule is checked by the build

`@Scheduled("0 0 25 * * *")` does not compile. The error names the hour field
and the range it violated.

That is only worth trusting if the build and the runtime agree about the
grammar, so they are not two parsers kept in step by discipline: the macro
plugin imports `CronExpression` from `FlightCronCore` — the same target the
scheduler runs — and validates with it. There is no second implementation to
drift.

Six fields, seconds first. The classic five-field crontab shape is accepted
and means the same schedule at second zero:

```
┌───────────── second        (0–59)
│ ┌─────────── minute        (0–59)
│ │ ┌───────── hour          (0–23)
│ │ │ ┌─────── day of month  (1–31)
│ │ │ │ ┌───── month         (1–12, or JAN–DEC)
│ │ │ │ │ ┌─── day of week   (0–6, Sunday = 0, or SUN–SAT)
0 0 3 * * *
```

`?`, `L`, `W`, `#` and `@daily`-style nicknames are **refused** rather than
guessed at. Implementations disagree about what they mean, and a schedule
that quietly means something other than its author intended is worse than one
that fails to parse.

## Running once, on one server or many

The common case needs no vocabulary for clustering:

```swift
@Scheduled("0 0 3 * * *")                          // runs once
@Scheduled(every: .minutes(5), onEveryNode: true)  // runs everywhere
```

The default is *once*, which reads the same whether there is one server or
five, and is the safe answer either way: a report that runs twice is a bug, a
report that runs once never is. `onEveryNode` is the opt-in for work that is
per-process by nature — warming an in-memory cache, trimming a local buffer.

On one server, "once" is simply what happens. On several it needs a
``JobCoordinator``, and if none is registered the scheduler **says so at
startup**:

```
warning: 3 job(s) are set to run once per firing, and no distributed
JobCoordinator is registered. That is correct on a single server. If you run
more than one, every one of them will run these jobs — register a coordinator.
```

That line exists because the failure it describes is otherwise silent: an
operator who believes once means once finds out from duplicated data, which
is the worst available place to learn it.

**No distributed coordinator ships yet.** ``LocalJobCoordinator`` is not a
stub — on a single process it is the correct implementation — but it cannot
span processes, and the scheduler does not pretend otherwise.

## When things go wrong

- **A job throws.** Logged, counted, and tried again at its next firing. One
  broken job does not stop the others, and never takes down the scheduler.
- **A run is still going when the next firing arrives.** Skipped by default,
  because piling a second copy onto a job that has grown slow is how a slow
  job becomes an outage. ``OverlapPolicy/queue`` waits instead.
- **The coordinator cannot be reached.** The firing is skipped. Not running
  is recoverable; running a once-only job on every server because a lock
  service blipped is not.
- **A schedule can never match again** — `0 0 0 30 2 *`, the 30th of
  February. Reported once and the job stops, rather than spinning on a
  question with no answer.

## Daylight saving

Schedules run in a time zone, defaulting to UTC rather than the machine's, so
a deployment behaves the same everywhere. On the two days a year it matters:

- **Spring forward.** A 02:30 job on the day 02:00–03:00 does not exist runs
  once, at 03:30 — late rather than not at all.
- **Fall back.** A 01:30 job on the day 01:00–02:00 happens twice runs once,
  because "daily at 01:30" promised once.

Intervals are different by nature: ``JobTrigger/interval(_:initialDelay:)``
measures from the *end* of the previous run and knows nothing about
wall-clock time. Use a cron expression when you mean a time of day.

## Testing without sleeping

``SchedulerClock`` is a seam, and `FlightSchedulerTesting` provides a clock
that jumps straight to each instant. A year of firings runs in microseconds,
and a suite that would otherwise go red on a loaded machine does not.

## Topics

### Declaring jobs

- ``Scheduler()``
- ``Scheduled(_:timeZone:onEveryNode:onOverlap:)``
- ``Scheduled(every:initialDelay:onEveryNode:onOverlap:)``

### Schedules

- ``JobTrigger``
- ``OverlapPolicy``
- ``JobScope``

### Running once across several servers

- ``JobCoordinator``
- ``LocalJobCoordinator``
- ``SchedulerMode``

### Observing

- ``SchedulerStatus``
- ``JobStatus``
- ``JobOutcome``

### Hosting

- ``FlightSchedulerModule``
- ``SchedulerService``
- ``SchedulerClock``
- ``SystemSchedulerClock``

### Registering by hand

- ``ScheduledJobRegistration``
