# Decisions taken without asking

Judgement calls made while executing `COMPOSITION-MIGRATION.md`'s work plan,
each with the alternatives it was chosen over and what reversing it costs.
Newest first. Nothing here is load-bearing on agreement — if a call reads
wrong, say so and it changes.

---

## D11 — A module is a value that holds what it provides

**The question.** `FlightModule.configure(_ container: Container)` is the last
thing keeping `Container` alive: 15 imperative registrations, the 7 framework
`context.resolve` sites that depend on them, and everything on §3's list that
those hold up. What replaces it, such that an optional subsystem's components
reach the generated graph *only when the application included that module*?

**Chosen.** A module stops registering components and starts **owning** them.
It declares what it needs as initializer parameters and what it provides as
stored properties:

```swift
public struct FlightChannelsModule: FlightModule {
    public static var dependencies: [any FlightModule.Type] { [FlightPubSubModule.self] }

    public let router: ChannelRouter
    public let broadcaster: ChannelBroadcaster

    public init(configuration: Configuration, pubsub: any PubSub) throws {
        let settings = try ChannelsConfiguration(configuration: configuration)
        self.router = ChannelRouter(settings: settings)
        self.broadcaster = ChannelBroadcaster(pubsub: pubsub)
    }
}
```

`FlightGraph` then holds the modules the application listed, and reaching a
framework component is `graph.channels.broadcaster` — two field loads, no
dictionary, no lock. Modules are nodes in the same graph as components,
ordered by the same `dependencies` DAG the runtime already resolves, taking
each other's products as parameters.

**Why this one.** It is what someone with no DI background would write. A
module is a struct with `let` properties and an `init`; the docs sentence is
"a module is a value that holds what it provides", and the follow-up question
"how do I get at what it provides" answers itself. There is no registry, no
bag, no lifetime vocabulary, and no second concept to learn — the mechanism a
module uses is the mechanism a component already uses.

It also deletes rather than adds:

- **Conditional inclusion stops being a runtime question.** The bootstrap
  list is a literal in the application's own source, which the generator
  already scans, and the `dependencies` DAG is already resolved there for
  lane ordering. A module the app did not list is simply not a property.
  That is what `flight:module-registered` exists to work around, and the
  marker goes with it.
- **The `service` timing workaround dissolves.** Modules hold a container
  today *only* because `service` is read before `freeze()`, so resolution has
  to be deferred into `run()` — §3 counts those wrappers as the largest
  category on the deletion list. A module that already holds its components
  can build its service from them directly.
- **The awkward cases get easier, not harder.** `(any PubSub)` falling back
  to a local implementation, and `PresenceTracker`'s three-way mode choice,
  are today container scans that ask "did anyone register an adapter". They
  become `init(adapter: (any DistributedPubSubAdapter)?)` and a `switch` —
  ordinary Swift, in the open, testable by calling it.

**Alternatives.**

- *Annotate framework components with their module* (`@Component(module:
  FlightChannelsModule.self)`). Smaller change, keeps `configure`. Rejected:
  it adds a concept — a back-reference from component to module — to preserve
  a mechanism we are trying to remove, and it does not touch the `service`
  workaround or the container-scan branches.
- *Attribute components by the Swift module they are declared in.* Needs no
  syntax at all and is tempting, but FlightSecurityCore declares both
  `FlightSecurityModule` and `FlightOIDCModule`; an app including only the
  first would get an OIDC validator built with no configuration. Too coarse
  by exactly the case §2.8 was built around.
- *Scan each `configure` body and transplant its registrations into the
  graph.* No new syntax, and it is the shape I reached for first. Rejected:
  a factory body is arbitrary Swift, so this is a source-to-source rewrite of
  `c.resolve(T.self)` into graph references — the "arbitrary wiring is
  genuinely lost" case §2.6 already identified, dressed up as automation.

**What it costs.** `init()` becomes an initializer with parameters, so
`Flight.bootstrap(modules: [Type.self])` cannot instantiate modules itself —
the generated composition root does, which is the same shift §2.8 declined to
make for the token validator alone and is now paid for once, for everything.
That is a breaking change to the first thing a new user encounters, and it is
the reason this is a decision rather than a refactor.

**Actuator's `FLIGHT_ENV` is a separate half, and stays separate.** The
module holding an `ActuatorController` is unconditional; whether its *routes*
install is the runtime question. That is §2.9a's install predicate — static
manifest entry, boolean evaluated once at boot — and it keeps the property
that a disabled actuator has no route rather than a route that 404s.

---

## D10 — Per-request construction is not shipped until the terminal can pass request values

**Context.** Step 6's spike proves per-request construction works for all
three response kinds, including the two that outlive dispatch. The obvious
next move is to make `@Controller` construct inside the handler closure
rather than capturing an instance resolved at `freeze()`. I did not.

**Why not.** Moving `try c.resolve(Self.self)` inside the closure buys the
*lifetime* and nothing else, because every component is a singleton now:
post-freeze resolution returns the same instance either way. What it costs is
a dictionary read per dependency per request, on every route. That is a
strictly worse trade until the terminal has something request-shaped to pass
— and nothing in the tree does yet, because §2.5 put the principal on the
context, which is where request values already travel typed and cheaply.

Per-request construction earns its cost when a controller's dependencies are
*visible in its signature* rather than read from the context ad hoc, and that
requires constructor injection from the graph — not a per-request locator
lookup wearing the same shape.

**So the order matters:** the graph must reach the terminal *first*, and then
construction moves. Shipping the lifetime change first would be measurable
cost for no behaviour, and would have to be undone.

**What shipped instead.** `makeFlightGraph(_:)` — the graph is now
*constructible*, not merely compilable, with its root parameters resolved
from the container. A function rather than a registration, because every
component is built eagerly at freeze and registering the graph would make a
missing root parameter fail the boot of an application that works today, for
a value nothing calls yet.

**The open decision**, recorded in §7 step 6 with trade-offs: how the
generated terminal gets graph values when `@Controller` expands in the
application's module and cannot know `FlightGraph` exists. My recommendation
is the macro emitting a per-route factory that takes a `make` closure, with
the generator supplying it — it keeps the handler thunk where it is, so the
drift `FlightRouteScan` was extracted to prevent stays prevented.

---

## D9 — `Lifetime` kept as a single-case enum, parameter defaulted

**Context.** §2.2 removed `.scoped` and `.transient`. `Lifetime` is now one
case, and `Container.register(_:qualifier:scope:stereotype:factory:)` still
takes it.

**Chosen.** Default the argument (`scope: Lifetime = .singleton`) rather than
remove the parameter.

**Why.** A single-case enum is zero-sized in Swift, so the parameter costs
nothing at runtime — removing it is API tidiness, not performance. Doing it
now would touch five macro implementations, the generator's bridge emission,
every module registration, 18 controller golden fixtures and the core macro
fixtures, in a change that buys no behaviour. Defaulting unblocks every call
site immediately and leaves the deletion as a clean, separable pass.

**Alternative.** Remove it now and absorb the churn while the surrounding
code is already moving. Defensible; I judged the review cost higher than the
benefit, and it can be done any time.

**Watch.** A one-case enum is an attractive nuisance — it reads as though
lifetimes are still a concept. If it survives to step 9 it should go.

---

## D8 — Long-lived responses are in scope, and what that requires is verified

**Context.** Step 6 constructs the request's object graph in the generated
route terminal. A streaming or upgraded response outlives the dispatch call
that produced it, so whatever the terminal built is still referenced after
dispatch returns. Confirmed as acceptable, provided those responses maintain
their own state and shut down gracefully while telling the client.

**Verified, not assumed.**

- **WebSockets.** `ChannelSocketHandler` routes a close *intent* from
  whichever task decided to end the session to the one place that writes the
  close frame, after every task has joined — the writer first, so queued
  frames reach the wire ahead of the close. Teardown is idempotent and runs
  `leave` per joined channel exactly once. Server-shutdown cancellation is an
  explicit path through it, and the documented close codes reach the client
  (they used to arrive as an abnormal 1006).
- **Streaming.** `Response.streaming` wires `onCancel: { producer.stop() }`,
  so a consumer going away — client disconnected, request task cancelled at
  shutdown — stops the producer rather than leaving it running against a
  stream nobody reads. Now pinned by a test; it was the one load-bearing
  property here with no coverage.

**The honest boundary.** Flight has no generic "server going away" *message*
for a byte stream. WebSocket has close codes; `.streaming` is opaque bytes
and SSE has no standard goodbye, so an application that wants to say
something on the way out sends it itself — it owns the writer. Flight's
guarantee is that the producer is stopped and nothing leaks, not that the
client is told why.

**Consequence for step 6.** Nothing the terminal constructs may own a
pooled resource (§2.12 already says this). With that held, a response
outliving dispatch is ordinary Swift lifetime and needs no scope.

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
