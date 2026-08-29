# Flight Scheduler

Cron and interval jobs as annotated methods, with the schedule checked by the
build.

```swift
@Scheduler
struct ReportJobs {
    @Autowired var reports: ReportService

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
it finds a `@Controller`. And a scheduled job is an ordinary method on an
ordinary component, so testing it needs no scheduler: construct the type with
a stub service and call the method.

Add `FlightSchedulerModule` to `bootstrap` and that is the whole setup.

## The schedule is a build error, not a 3am surprise

```swift
@Scheduled("0 0 25 * * *")                     // error: hour: 25 is out of range 0–23
@Scheduled("0 0 9 * * *", timeZone: "America/NewYork")   // error: not an IANA identifier
```

Worth trusting only if the build and the runtime agree about the grammar, so
they are not two parsers kept in step by discipline. The macro plugin imports
`CronExpression` from `FlightCronCore` — the same target the scheduler runs —
and validates with it. There is no second implementation to drift.

The time zone is checked the same way, against Foundation's own database: a
missing underscore used to compile cleanly and run the job in GMT with
nothing said, which is the 3am surprise this section is named for.

Six fields, seconds first; the classic five-field crontab shape means the
same schedule at second zero.

```
┌───────────── second        (0–59)
│ ┌─────────── minute        (0–59)
│ │ ┌───────── hour          (0–23)
│ │ │ ┌─────── day of month  (1–31)
│ │ │ │ ┌───── month         (1–12, or JAN–DEC)
│ │ │ │ │ ┌─── day of week   (0–6, Sunday = 0, or SUN–SAT)
0 0 3 * * *
```

Seconds are present because a scheduler that cannot say "every fifteen
seconds" is one people stop using and write a loop instead.

`?`, `L`, `W`, `#` and `@daily`-style nicknames are **refused** rather than
guessed at: implementations disagree about what they mean, and a schedule
that quietly means something other than its author intended is worse than one
that fails to parse.

## Running once, on one server or many

```swift
@Scheduled("0 0 3 * * *")                          // runs once
@Scheduled(every: .minutes(5), onEveryNode: true)  // runs everywhere
```

The default is *once*, which reads the same whether you have one server or
five, and is the safe answer either way: a report that runs twice is a bug, a
report that runs once never is. `onEveryNode` is the opt-in for work that is
per-process by nature — warming an in-memory cache, trimming a local buffer.
Note that no cluster vocabulary appears unless you have a cluster.

On one server, "once" is simply what happens. On several it needs a
`JobCoordinator`, and if none is registered the scheduler says so at startup:

```
warning: 3 job(s) are set to run once per firing, and no distributed
JobCoordinator is registered. That is correct on a single server. If you run
more than one, every one of them will run these jobs — register a coordinator.
```

That line exists because the failure it describes is otherwise silent. An
operator who believes once means once finds out from duplicated data, which
is the worst available place to learn it.

**No distributed coordinator ships yet.** `LocalJobCoordinator` is not a stub
— on a single process it is the correct implementation — but it cannot span
processes, and the scheduler does not pretend otherwise. The protocol is
three methods, implementable against anything offering an atomic conditional
write.

## When things go wrong

| | |
|---|---|
| A job throws | Logged, counted, retried at its next firing. One broken job never stops the others. |
| A run overruns its next firing | Skipped by default — piling a second copy onto a slow job is how a slow job becomes an outage. `.queue` holds the firing and runs it when the job finishes, never alongside; a job more than one firing behind keeps only the newest, and says so. Applies to cron schedules, the only kind with firing instants that can arrive while a run is in progress: an interval is measured from the end of the previous run, so it cannot overlap by construction. |
| The coordinator is unreachable | The firing is skipped. Not running is recoverable; running a once-only job everywhere because a lock service blipped is not. |
| The schedule can never match again | Reported once, and that job stops rather than spinning on a question with no answer. The other jobs carry on — one runner ending is not the scheduler ending. |
| An interval job is set to run once, with a coordinator registered | Logged as an error at startup, and it runs on every node anyway. An interval's firing instants come from each node's own last run, so no two nodes ever claim the same firing and every claim succeeds. Coordinate it with a cron expression, or say `onEveryNode: true`. |
| An interval is zero or negative | Startup fails, naming the job. `Duration` is not a literal, so the macro cannot catch it; a firing every time round the loop is a pinned core, not a schedule. |

## Daylight saving

Schedules run in a time zone, defaulting to UTC rather than the machine's, so
a deployment behaves the same everywhere. On the two days a year it matters:

- **Spring forward** — a 02:30 job on the day 02:00–03:00 does not exist runs
  once, at 03:30. Late, rather than not at all.
- **Fall back** — a 01:30 job on the day 01:00–02:00 happens twice runs once,
  because "daily at 01:30" promised once. Asked from *inside* the repeated
  hour — a process that booted at 01:20 on the second pass — the answer is
  the second 01:30, since the first is already gone.

Both are pinned by tests, and so is the third case. The first caught a real
bug during development: the search normalized its own state through
`Calendar`, which resolved the missing hour mid-search and skipped the whole
day. The third caught a worse one: Foundation resolves an ambiguous wall time
to the first pass, so a query from inside the second pass was answered with
an instant up to an hour in the *past* — and the runner then slept for no
time at all, fired, recomputed the same past instant, and spun until real
time left the fold.

Intervals are a different thing on purpose: they measure from the *end* of
the previous run and know nothing about wall-clock time, so a job taking
longer than its period is never perpetually late. Use a cron expression when
you mean a time of day.

## Observing

`SchedulerStatus` is a resolvable component — last firing, last outcome, next
firing, run and failure counts:

```swift
@Controller("/jobs")
struct JobsController {
    @Autowired var scheduler: SchedulerStatus

    @GetMapping("/")
    func index(_ context: RequestContext) -> [JobStatus] {
        scheduler.snapshot()
    }
}
```

Deliberately not an actuator endpoint: the actuator collects what it shows
through generic container introspection, and adding a scheduler endpoint
there would make every app that wants `/actuator/health` link the scheduler.

## Testing without sleeping

`SchedulerClock` is a seam and `FlightSchedulerTesting` ships a clock that
jumps straight to each instant, so a year of firings runs in microseconds.
`StubJobCoordinator.refusing` exercises the "another process took this
firing" path, which is otherwise reachable only by running two servers.

## What is not here

No persistence: a job that must survive a restart with its history intact
wants a queue, not a scheduler. No misfire backfill — a process that was down
at 03:00 does not run yesterday's job when it comes up at 09:00, because
"catch up on everything you missed" is rarely what a nightly report wants and
never what a billing run does. No retries beyond the next firing.
