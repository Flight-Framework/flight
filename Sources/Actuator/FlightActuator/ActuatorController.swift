import FlightCore
import FlightWeb
import Foundation

/// The dashboard. A plain struct, not `@Controller` — deliberately: it is
/// built and held by ``ActuatorModule`` (in its controller box), and its
/// routes are values the module declares.
///
/// Flight Core's registration plugin scans every recursive source-module
/// dependency that sits atop FlightCore for `@Component`/`@Controller`
/// types — right for an app-owned library target (so an app never has to wire
/// it), wrong for a starter package with its own `FlightModule`: a downstream
/// app's generated composition root would try to build this type as one of
/// its own graph nodes — bypassing `ActuatorModule`'s exposure gate entirely
/// (whole point) and colliding with what `ActuatorModule` already does. Every
/// other starter (`flight-web`, `flight-pubsub`, `flight-channels`,
/// `flight-data-postgres`) avoids this the same way: none put
/// `@Component`/`@Controller` on their own infrastructure, wiring it from that
/// package's own `FlightModule` instead. This mirrors that.
///
/// Internal deliberately: `ActuatorModule` constructs it and serves it through
/// route values (`RouteRegistration`, the same seam `@GetRoute` sits beside);
/// nothing outside this package touches it directly.
struct ActuatorController {
    /// Every component, as the *build* scanned them — passed in by the
    /// composition root rather than read from `container.allRegistrations()`.
    ///
    /// A better answer than the container's, and available before the process
    /// starts: what the build found is what the graph constructs. It does not
    /// carry anything registered through the imperative escape hatch, which is
    /// the deliberate trade — see COMPOSITION-MIGRATION.md §2.9.
    let components: [ComponentDescriptor]

    /// Module health is genuinely runtime state, so it still comes from the
    /// thing that tracks it.
    let health: @Sendable () -> [ModuleStatus]

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
        // `health()` rather than a full `ActuatorSnapshot`: the snapshot also
        // copies the entire component descriptor table, and this path used
        // every bit of it to compute three integers — on the one route an
        // orchestrator polls every few seconds.
        let modules = health()
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
        let snapshot = ActuatorSnapshot(
            environment: environment, modules: health(), components: components)
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
