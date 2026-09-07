# Decisions taken without asking

Judgement calls made while executing `COMPOSITION-MIGRATION.md`'s work plan,
each with the alternatives it was chosen over and what reversing it costs.
Newest first. Nothing here is load-bearing on agreement — if a call reads
wrong, say so and it changes.

---

## D7 — The request's identity is a seam protocol in Flight Web

**Context.** Step 3 moves the principal onto `RequestContext` as a typed
field. But `RequestContext` lives in FlightWeb and `Principal` lives in
FlightSecurityCore, which *depends on* FlightWeb — so the field cannot name
the type. This is the real reason the principal travelled as a `.scoped`
component: the container inverted a dependency the type system would not
allow directly. The stale "the middleware chain is flat" story was a second
reason, and the smaller one.

**Chosen.** FlightWeb owns `RequestPrincipal` — a two-member seam (`subject`,
`hasRole`) — and `RequestIdentity`, a three-case enum stored on the context.
`FlightSecurityCore.Principal` conforms.

**Why.** FlightChannels already solved the identical problem this way, and its
`ChannelPrincipal` doc argues the case: the package that needs to *read* an
identity owns a minimal protocol and depends on no particular identity
implementation. Using the same shape twice is cheaper to explain than two
mechanisms. It also keeps §2.5's "named fields, closed set, no
`get(Key.self)`" property.

**Alternatives.**

- *Move `Principal` down into FlightWeb or FlightCore.* Ends the cycle
  outright, but puts JWT-shaped identity in the web layer and makes every app
  that never authenticates carry it.
- *A typed side-table*, like the `ServiceContext` the context already holds.
  Works, and §6 concedes the "bags are wrong" premise was mistaken — but it
  reintroduces a `get(Key.self)` surface for one entry.
- *An opaque `any Sendable` slot* with typed accessors in FlightSecurityCore.
  Smallest change; a one-entry untyped bag wearing a field's clothes.

**Cost of reversing.** Contained: the protocol, the enum, one field, and the
accessors in `RequestContext+Principal.swift`.

**Measured.** The identity field costs 40 bytes (existential). `.anonymous`
carries no payload, so an unauthenticated request pays no retain/release
traffic when the context is copied.

---

## D6 — `RequestContext.response` deleted

**Context.** While sizing the context for D7 I measured it at **184 bytes**,
of which `response: Response` was 97. It was written in two places and read
in none: `Router.execute` assigned it and then returned the same value, and
`RequestContext.init` stored it.

**Chosen.** Delete the field and the dead store.

**Why.** It is vestigial from the flat pre-handler chain, where middleware
mutated a response in place and the chain returned it at the end. Under
`handle(_:next:) -> Response` the response *is* the return value. The context
is copied on every `next(context)`, so this was 97 dead bytes per layer per
request, and it is what pushed the struct across a third cache line.

**Result.** 184 → **120 bytes**, three cache lines → two, *including* D7's new
40-byte field. `RequestContextLayoutTests` pins the bound so crossing it again
is a decision rather than an accident.

**Alternatives.** Deprecate rather than remove — it is public API. Rejected:
it is dead, this migration is already breaking, and a deprecated field still
costs the bytes.

**Cost of reversing.** Trivial, but it would put the third cache line back.

---

## D5 — `AuthenticationState` kept, as a derived view

**Context.** With identity stored as `any RequestPrincipal`,
FlightSecurityCore's `AuthenticationState` (which carries a concrete
`Principal`) is no longer the storage.

**Chosen.** Keep it as a public type, computed from `RequestIdentity` on
read. An identity written by a *different* conformer reports `.anonymous`.

**Why.** `context.authenticationState` is documented public API and the
distinction it draws — no credential vs rejected credential — is what earns
the RFC 6750 `error="invalid_token"` challenge. Deleting it would break
callers for no gain.

**Alternative.** Delete it and let `RequestIdentity` be the only type.
Cleaner, one fewer concept, and a breaking change to a documented surface.
Worth doing if the seam ever grows a second conformer in practice.

**Watch.** The `as? Principal` downcast on every `context.principal` read. A
handler reading it several times pays several dynamic casts. Not measured;
suspected negligible against a request, but it is the one wart here.

---

## D4 — The generator scans routes silently

**Chosen.** `flight-registration-gen` runs the shared route scanner with a
diagnostics sink that discards everything.

**Why.** `@Controller` already diagnoses non-literal paths, static handlers,
bad signatures and upgrades with bodies, and both run in the same build.
Anything the generator reported would reach the author twice at the same
line. The macro owns reporting; the generator owns the manifest.

**Alternative.** Report from the generator and stop reporting from the macro.
Rejected: the macro's diagnostics render inline at the attribute in an IDE,
and a build tool's do not.

---

## D3 — Mounts are recorded; `registerRoute` is acknowledged

**Chosen.** `assets(at:)`, `uploads(at:)` and `registerChannelSocket` are
recorded as *mounts* from their call site. Direct `registerRoute` calls warn
unless marked `// flight:hand-registered`, and are named in the generated
file either way.

**Why.** A mount's call site carries the prefix the framework derives routes
from, so it is scannable even though the `registerRoute` calls inside the
convenience are not. Only the raw escape hatch is genuinely uncomputable, and
the component scan already had an answer for that shape.

**Alternatives.** Union the manifest with runtime collection (keeps the
container alive for routing, which is what step 4 removes); or hard-error on
unscannable calls (turns a working escape hatch into a build failure, first
in framework code the author does not own).

---

## D2 — Lane order is derived from the module graph, with scan-order roots

**Chosen.** Sort lane declarations by a depth-first walk of scanned
`static var dependencies` edges, using every scanned module as a root in scan
order.

**Why.** The runtime's roots are the bootstrap module list, which is outside
the generator's scope. Scan order reproduces the runtime wherever a
dependency path exists between two modules — the ordinary case, since an
application module depends on the framework modules it uses — and cannot
where none does.

**Mitigation.** The scanned edges are emitted as `moduleGraph`, so a consumer
holding the real bootstrap list can redo the sort correctly.

**Alternative.** Scan the `Flight.bootstrap(modules:)` call for the roots.
Exact, and brittle: several call sites, test harnesses among them.

---

## D1 — `@Scheduler` maps to the `component` stereotype

**Chosen.** The manifest reports `@Scheduler` types as `component`.

**Why.** `Stereotype` has no scheduler case, and the macro passes no
`stereotype:` argument, so `.component` is what the runtime records.
Inventing a case in a build tool would put the manifest and the runtime out
of step.

**Alternative.** Add `Stereotype.scheduler` and have both use it — a small,
real improvement to Actuator's grouping, and a change to a Core enum that
this work did not need.
