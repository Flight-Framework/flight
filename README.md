# Flight Actuator

A lightweight, no-frills introspection surface for a running Flight app —
what beans are registered, which modules are healthy, basic runtime facts —
served over HTTP. The design rationale lives in
[flight-actuator-design.md](flight-actuator-design.md); this README covers
usage and records where the implementation had to make choices the design
left open.

## Usage

Actuator is an ordinary `FlightModule` — registered like everything else,
with no special access to Core or Web (§2):

```swift
import FlightActuator

try await bootstrap(
    configuration: try Configuration.load(),
    modules: [
        FlightWebModule<FlightTransport>.self,
        ActuatorModule.self,
        AppModule.self,
    ]
)
```

`GET /actuator` then serves the dashboard — server-rendered HTML by
default, or the same data as JSON:

```yaml
# flight.yaml
actuator:
  format: ssr   # or "json"
```

(or `FLIGHT_ACTUATOR_FORMAT=json` via the env-var config layer). The key is
read once at bootstrap. An absent key means SSR; a present-but-malformed
value fails bootstrap loudly, naming the key and value — never a silent
fallback (Flight Config §5).

## Access gating (§4.1)

In `.prod` (per `FLIGHT_ENV`) the routes are simply **not registered** —
`/actuator` does not exist in the route table, so there is nothing to probe
or misconfigure. Prod access is a seam reserved for Flight Security (§4.2)
and deliberately not built.

For tests and embedders, `ActuatorModule(environment:)` bypasses the
`FLIGHT_ENV` read; `TestContainer.build` honors such ready-made instances.

## JSON contract

The JSON rendering is a public contract for hand-rolled front-ends. Shape
(stable, sorted keys; absent optionals are *omitted*, not `null`-encoded):

```json
{
  "environment": "dev",
  "modules": [
    {"module": "AppModule", "health": "running"},
    {"module": "JobsModule", "health": "failed", "error": "…"}
  ],
  "beans": [
    {"type": "App.UserService", "scope": "singleton",
     "stereotype": "service", "qualifier": "primary",
     "sourceModule": "AppModule"}
  ]
}
```

- `health`: `"notStarted" | "running" | "failed"` (`error` present only for
  `"failed"`)
- `scope`: `"singleton" | "transient" | "scoped"`
- `stereotype`: `"component" | "service" | "repository" | "controller"`

The encoding is hand-written rather than retroactive `Codable` on Core's
types, so Core can evolve its introspection structs without silently
changing this wire format.

## Design deltas

Recorded here the same way sibling packages record theirs:

1. **`ActuatorController` is a plain struct, hand-registered — not
   `@Controller`.** An early revision used `@Controller` (the design's own
   §4.1 sketch, `container.register(ActuatorController.self, scope:
   .singleton) { ... }`, was implemented as the macro instead) and broke the
   moment a real app depended on this package: Flight Core's registration
   plugin scans *every* recursive source-module dependency that sits atop
   FlightCore — right for an app-owned library target, wrong for a starter
   package with its own `FlightModule`. A downstream app's generated
   `flightRegisterAll` tried to register `ActuatorController` itself,
   unconditionally — bypassing the `.prod` gate entirely (§4.1's whole
   point) and colliding with the registration `ActuatorModule` already
   performs. Every sibling starter (`flight-web`, `flight-pubsub`,
   `flight-channels`, `flight-data-postgres`) avoids this the same way: none
   of them put `@Component`/`@Controller` on their own infrastructure.
   Restored to the design doc's original sketch: `ActuatorModule.configure`
   registers the controller and its route by hand (`registerRoute`, the
   escape hatch `@GetMapping` sits beside).
2. **The container is no longer a registered bean at all.** A consequence
   of (1): `ActuatorController` now holds `container` as a plain stored
   property, captured directly from `configure(_:)`'s own parameter — no
   `@Autowired`, so nothing needs `Container` to be resolvable, and the
   guarded self-registration (and its duplicate-registration-avoidance
   dance) is gone.
3. **The gate's environment is a qualified bean.** The dashboard reports
   the same environment the registration gate ran against, injected as
   `FlightEnvironment` with qualifier `"flight.actuator"`, rather than
   re-reading `FLIGHT_ENV` per request. The two can otherwise disagree
   under the explicit-environment initializer.
4. **`ModuleHealth.isFailed` (and friends) live here.** The design's own
   test sketch uses `health.isFailed`; Core keeps `ModuleHealth` minimal,
   so the presentation predicates and stable labels ship in this package
   as extensions.
5. **Config read happens at freeze, not `configure`.** `resolve()` is
   illegal during the registration phase by Core's contract, so
   `actuator.format` is read inside the controller's registration factory,
   which runs once at `freeze()`'s eager singleton construction — before
   any request, matching what `@ConfigValue` would have given. Reached via
   `Configuration.getIfPresent(_:as:) ?? .ssr`, not `get(_:default:)`: the
   latter is non-throwing and `fatalError`s on a malformed *present* value;
   `getIfPresent` throws instead, so a malformed value still fails module
   configuration loudly (§5) rather than trapping the process — the same
   distinction the `@ConfigValue` macro's own `default:` expansion relies
   on.

`ActuatorController`'s registration is explicitly tagged
`stereotype: .controller`, so it groups under *Controllers* on its own
dashboard, same as it would have under the macro — no dependency on
whatever `@Controller`'s own stereotype-tagging does upstream.

## Testing

No HTTP round-trip is required to test the data assembly (§6) —
`ActuatorSnapshot` is a plain `Sendable` struct assembled from
`Container.moduleStatuses()` / `allRegistrations()`. The suite covers
environment gating, snapshot assembly (including a module whose service
fails through the real `assemble` health-tracking path), both renderings,
HTML escaping of hostile registration metadata, and config resolution:

```
swift test
```

## Non-goals

No auth (until Flight Security exists), no live-updating dashboard, no
historical/metrics data, no per-bean instance inspection — see design doc
§7.
