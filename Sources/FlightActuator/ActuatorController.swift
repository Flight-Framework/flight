import FlightCore
import FlightWeb
import Foundation

/// The dashboard (§5). A plain struct, not `@Controller` — deliberately,
/// and per the design doc's own §4.1 sketch (`container.register(
/// ActuatorController.self, scope: .singleton) { ... }`).
///
/// Flight Core's registration plugin scans every recursive source-module
/// dependency that sits atop FlightCore for `@Component`/`@Controller`
/// types — right for an app-owned library target (so an app never has to
/// hand-register it), wrong for a starter package with its own
/// `FlightModule`: a downstream app's generated `flightRegisterAll` would
/// try to register this type *itself*, unconditionally — bypassing
/// `ActuatorModule`'s `.prod` gate entirely (§4.1's whole point) and
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

    func dashboard(_ context: RequestContext) async throws -> Response {
        let snapshot = ActuatorSnapshot(container: container, environment: environment)
        switch format {
        case .ssr:
            return .html(renderActuatorHTML(snapshot))
        case .json:
            let encoder = JSONEncoder()
            // Deterministic output: the JSON is a public contract for
            // hand-rolled front-ends (§5), so key order should not wobble
            // between requests or releases.
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return .data(try encoder.encode(snapshot), contentType: .json)
        }
    }
}
