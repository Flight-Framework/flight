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
/// `@GetRoute` sits beside); nothing outside this package touches it
/// directly.
struct ActuatorController {
    let container: Container
    let environment: FlightEnvironment
    let format: ActuatorFormat

    /// Overall health, with nothing in it worth hiding.
    ///
    /// Deliberately minimal: an overall status and per-module counts, with no
    /// component list, no type names, and no failure text. This is the one
    /// actuator surface safe to publish unauthenticated in production, and it
    /// is only safe because of what it leaves out — a probe needs to know
    /// whether to act, not what the pod is made of.
    ///
    /// `200` when every module is running, `503` otherwise, so an
    /// orchestrator can read the status code alone. This is the strict
    /// reading, which is the readiness question; see ``liveness(_:)`` for the
    /// one an orchestrator should restart on.
    func health(_ context: RequestContext) async throws -> Response {
        try respond(to: .readiness)
    }

    /// Is this process wedged — should the orchestrator restart it?
    ///
    /// A module that has not started yet does **not** count against liveness:
    /// a slow-starting pod answering `DOWN` here gets killed and restarted
    /// into the same slow start, forever. Only a module whose service threw
    /// counts, because that is the state a restart can actually clear.
    func liveness(_ context: RequestContext) async throws -> Response {
        try respond(to: .liveness)
    }

    /// Can this process serve traffic yet?
    ///
    /// Strict: a module still starting, or failed, means no. Identical to
    /// ``health(_:)``, and named so a deployment does not have to know that.
    func readiness(_ context: RequestContext) async throws -> Response {
        try respond(to: .readiness)
    }

    /// Which question a probe is asking. One endpoint answered both, and the
    /// two want opposite things from a module that has not started yet.
    private enum Probe {
        case liveness
        case readiness
    }

    private func respond(to probe: Probe) throws -> Response {
        // `moduleStatuses()` rather than a full `ActuatorSnapshot`: the
        // snapshot also copies the entire component registration table, and this
        // path used every bit of it to compute three integers — on the one
        // route an orchestrator polls every few seconds.
        let modules = container.moduleStatuses()
        let failed = modules.filter(\.health.isFailed).count
        let notStarted = modules.filter(\.health.isNotStarted).count
        let up =
            switch probe {
            case .liveness: failed == 0
            case .readiness: failed == 0 && notStarted == 0
            }

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
                modules: modules.count,
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
