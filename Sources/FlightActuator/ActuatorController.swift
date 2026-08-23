import FlightCore
import FlightWeb
import Foundation

/// The dashboard. A plain struct, not `@Controller` — deliberately;
/// registered by hand with `container.register(ActuatorController.self,
/// scope: .singleton) { ... }`.
///
/// Flight Core's registration plugin scans every recursive source-module
/// dependency that sits atop FlightCore for `@Component`/`@Controller`
/// types — right for an app-owned library target (so an app never has to
/// hand-register it), wrong for a starter package with its own
/// `FlightModule`: a downstream app's generated `flightRegisterAll` would
/// try to register this type *itself*, unconditionally — bypassing
/// `ActuatorModule`'s `.prod` gate entirely (whole point) and
/// colliding with the registration `ActuatorModule` already performs (a
/// duplicate-registration trap). Every other starter (`flight-web`,
/// `flight-pubsub`, `flight-channels`, `flight-data-postgres`) avoids this
/// the same way: none of them put `@Component`/`@Controller` on their own
/// infrastructure, only ever registering it by hand from that package's own
/// `FlightModule`. This mirrors that.
///
/// Internal deliberately: `ActuatorModule` constructs and registers it (as
/// an ordinary route via `registerRoute`, the same escape hatch
/// `@GetMapping` sits beside); nothing outside this package touches it
/// directly.
struct ActuatorController {
    let container: Container
    let environment: FlightEnvironment
    let format: ActuatorFormat

    /// Liveness and readiness, with nothing in it worth hiding.
    ///
    /// Deliberately minimal: an overall status and a per-module up/down, with
    /// no component list, no type names, and no failure text. This is the one
    /// actuator route safe to publish unauthenticated in production, and it
    /// is only safe because of what it leaves out — a probe needs to know
    /// whether to restart the pod, not what the pod is made of.
    ///
    /// `200` when every module is running, `503` otherwise, so an orchestrator
    /// can read the status code alone.
    func health(_ context: RequestContext) async throws -> Response {
        let snapshot = ActuatorSnapshot(container: container, environment: environment)
        let failed = snapshot.modules.filter(\.health.isFailed).count
        let notStarted = snapshot.modules.filter(\.health.isNotStarted).count
        let up = failed == 0 && notStarted == 0

        struct Health: Encodable {
            let status: String
            let modules: Int
            let failed: Int
            let notStarted: Int
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let body = try encoder.encode(
            Health(
                status: up ? "UP" : "DOWN",
                modules: snapshot.modules.count,
                failed: failed,
                notStarted: notStarted))
        return .data(
            body, contentType: .json, status: up ? .ok : .serviceUnavailable)
    }

    func dashboard(_ context: RequestContext) async throws -> Response {
        let snapshot = ActuatorSnapshot(container: container, environment: environment)
        switch format {
        case .ssr:
            return .html(renderActuatorHTML(snapshot))
        case .json:
            let encoder = JSONEncoder()
            // Deterministic output: the JSON is a public contract for
            // hand-rolled front-ends, so key order should not wobble
            // between requests or releases.
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return .data(try encoder.encode(snapshot), contentType: .json)
        }
    }
}
