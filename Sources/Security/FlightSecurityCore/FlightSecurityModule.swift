import FlightCore
import FlightWeb
import Logging
import ServiceLifecycle

/// Authentication wiring, independent of how tokens are validated.
///
/// Registers:
/// - ``Authentication`` in its own lane, ahead of whatever the application
///   declares in its own — lanes compose across `MiddlewareRegistration.lane`
///   declarations rather than conflict;
/// - the two canonical security lanes, `PipelineLane.authentication` and
///   `PipelineLane.authenticated`, filled with what their documentation says
///   they contain.
///
/// It does **not** provide a ``TokenValidator``. Supplying one is the
/// application's choice, made by listing a module:
///
/// - ``FlightOIDCModule`` for OIDC/JWT — the common case;
/// - any module of your own that provides `(any TokenValidator)`, for
///   session cookies, API keys, mTLS, HMAC, or anything else.
///
/// With neither, there is no `(any TokenValidator)` to supply, and
/// `FlightSecurityModule` cannot be built — its initializer requires one, so
/// composition fails loudly at startup rather than at the first request.
///
/// ``RequireAuthentication`` is deliberately *not* in the **default** lane —
/// unlike authentication itself, enforcement is not something every route
/// wants. It is what the `.authenticated` lane is for, and a route or
/// controller opts in by naming that lane.
///
/// ## Why the validator is not a default here
///
/// This module used to register an OIDC validator unless it found that the
/// application had already registered its own, by scanning
/// `container.allRegistrations()`. That seam depended on three implicit
/// things: the scan matching a type name, the application's module being
/// configured *before* this one (registering after it silently lost), and an
/// internal flag that also decided whether a JWKS refresher ran. Choosing a
/// module instead is explicit, order-independent, and visible at the
/// bootstrap call site.
public struct FlightSecurityModule: FlightModule {

    /// The authentication stack, as values.
    ///
    /// Whether these exist is a property of "did this application include a
    /// security module", which no build-time scan can decide — so they are
    /// this module's to provide, and the composer hands them to
    /// `FlightWebModule` along with everyone else's.
    ///
    /// The canonical security lanes are declared here because the whole point
    /// of a canonical spelling is that naming it works. `PipelineLane`
    /// documents what each contains, `@Controller(pipelines:)` recognizes both
    /// by name, and the controller macro warns when a route silently drops
    /// one — three things that described a stack no module was building.
    /// Without them, `pipelines: [.authenticated]` fails at bootstrap with
    /// `UndeclaredLaneError`.
    ///
    /// A lane is the *whole* stack for a route naming it alone, so each starts
    /// with `Authentication`: `[.authenticated]` must establish the identity
    /// it then requires, without depending on the default lane it replaced.
    public let middleware: [MiddlewareRegistration]

    /// - Parameter validator: How tokens are validated — from
    ///   `FlightOIDCModule`, or from a module of your own. It used to be
    ///   resolved per request by `Authentication`'s `@Inject`; the middleware
    ///   is a value now, so it is handed the validator once.
    public init(validator: any TokenValidator) {
        let authentication = Authentication(validator: validator)
        let require = RequireAuthentication()
        self.middleware =
            MiddlewareRegistration.lane(.default, [authentication])
            + MiddlewareRegistration.lane(.authentication, [authentication])
            + MiddlewareRegistration.lane(.authenticated, [authentication, require])
    }

    public init() {
        preconditionFailure(
            "FlightSecurityModule takes a token validator in init(validator:), so it cannot be "
                + "instantiated from its type. List FlightOIDCModule, or a module of your own that "
                + "provides `(any TokenValidator)`, and let the composition root wire it.")
    }

}

/// OIDC/JWT token validation: the default implementation of the seam
/// ``FlightSecurityModule`` leaves open.
///
/// Provides ``OIDCTokenValidator`` — configured from `security.oidc.*` — as
/// `(any TokenValidator)`, and owns the JWKS maintenance service that keeps
/// its key cache warm. Both travel together, because both are OIDC's and
/// neither means anything without the other.
///
/// Missing required configuration (`security.oidc.issuer` / `audience`) fails
/// at composition — startup, not first request.
///
/// List this module to get OIDC. Omit it and provide your own
/// `(any TokenValidator)` to authenticate any other way.
public final class FlightOIDCModule: FlightModule {
    public static var dependencies: [any FlightModule.Type] {
        [FlightSecurityModule.self]
    }

    /// `security.oidc.*`, read once at composition.
    public let settings: OIDCSecurityConfiguration

    /// The validator, concretely — and what the JWKS refresher maintains.
    public let validator: OIDCTokenValidator

    /// The same validator as the existential.
    ///
    /// Typed this way deliberately: it is what `FlightSecurityModule` takes,
    /// and the composer matches provider to parameter by type. A concrete
    /// property would not match `validator: any TokenValidator`, and the
    /// generator has source text rather than a conformance table.
    public let tokenValidator: any TokenValidator

    public init(configuration: Configuration) throws {
        let settings = try OIDCSecurityConfiguration(configuration: configuration)
        let validator = OIDCTokenValidator(configuration: settings)
        self.settings = settings
        self.validator = validator
        self.tokenValidator = validator
    }

    public init() {
        preconditionFailure(
            "FlightOIDCModule takes its configuration in init(configuration:), so it cannot be "
                + "instantiated from its type. Pass `composedBy: flightComposeModules` to "
                + "Flight.run — `flight new` writes that argument — or construct the module "
                + "yourself and use the entry point taking module instances.")
    }

    public var service: (any Service)? {
        JWKSMaintenanceService(validator: validator)
    }
}

/// Keeps the process-wide JWKS cache warm: one fetch at
/// startup so the first request never pays IdP latency, then a refresh per
/// cache-TTL. Fetch failures are logged and retried on the next tick —
/// token validation falls back to lazy fetching (and stale-serving), so an
/// IdP blip never takes the app down.
///
/// Takes the validator it maintains. It used to hold a `Container` and
/// resolve at `run()`, because `FlightModule.service` is read before
/// `freeze()` and the validator did not exist yet — the indirection
/// COMPOSITION-MIGRATION.md §3 said would go away with composition.
/// `FlightOIDCModule` builds the validator in its own initializer, so there
/// is nothing left to look up.
final class JWKSMaintenanceService: Service {
    private let validator: OIDCTokenValidator
    private let logger = Logger(label: "flight.security.jwks")

    init(validator: OIDCTokenValidator) {
        self.validator = validator
    }

    func run() async throws {
        // Unconditional: this service belongs to FlightOIDCModule, which owns
        // the validator it maintains. Previously it lived on the security
        // module, could not know whether OIDC was in play, and had to park
        // forever when it wasn't.
        let validator = self.validator
        let interval = Duration.seconds(max(validator.keyRefreshInterval, 60))
        do {
            try await cancelWhenGracefulShutdown {
                await self.refresh(validator, context: "pre-warm")
                while !Task.isCancelled {
                    try await Task.sleep(for: interval)
                    await self.refresh(validator, context: "scheduled refresh")
                }
            }
        } catch is CancellationError {
            // Graceful shutdown.
        }
    }

    private func refresh(_ validator: OIDCTokenValidator, context: String) async {
        do {
            try await validator.refreshKeys()
            logger.debug("JWKS \(context) complete")
        } catch {
            logger.warning(
                "JWKS \(context) failed; validation will fetch lazily",
                metadata: ["reason": "\(error)"]
            )
        }
    }
}
