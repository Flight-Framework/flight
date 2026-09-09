import FlightCore
import Logging
import ServiceLifecycle

/// The composition-root module (§5.3, §8): choosing a transport is choosing
/// which of these to include —
///
///     try await Flight.bootstrap(
///         configuration: .load(),
///         modules: [FlightWebModule<FlightTransport>.self, AppModule.self]
///     )
///
/// Its `configure` registers nothing; controllers register themselves (and
/// their routes) through the ordinary pipeline from any module. Its service
/// slots into bootstrap step 8, and request serving begins only once step
/// 9's ServiceGroup runs — which is what guarantees every handler's
/// `@Inject` dependencies are fully resolved before the first request
/// arrives (§8).
///
/// A class, because `configure` is where the container that a
/// `RequestContext` carries becomes available — dispatch is built there, from
/// values this module already holds, and the service reads it after. The
/// registries are no longer collected from the container at `freeze()`; only
/// request-time resolution still needs one, and that goes when
/// `context.resolve` does (COMPOSITION-MIGRATION.md §9).
public final class FlightWebModule<Transport: ServerTransport>: FlightModule, @unchecked Sendable {

    /// Every route in the application: the generated ones, plus whatever each
    /// module declares. The composition root concatenates them.
    public let routes: [RouteRegistration]

    /// Every middleware, with the lanes they declare.
    public let middleware: [MiddlewareRegistration]

    /// Static-asset mounts, which are routing fallbacks rather than routes.
    public let assetMounts: [AssetMountRegistration]

    /// Encoders and decoders, read from `web.*` once at composition. A
    /// misspelled `web.json.date-strategy` fails here rather than on
    /// whichever request first encoded something.
    public let coders: WebCoders

    /// The application's error mapper, when a module provided one — matched by
    /// type in composition, the same way `coders` is. `.none` declines
    /// everything, the default for an app that maps no errors of its own.
    public let errorMapper: ErrorMapper

    /// The transport's own settings come from here at start-up.
    private let configuration: Configuration

    /// Built in `configure`, read by `service`.
    private let dispatch: Dispatch

    /// - Parameter coders: An application's own encoders/decoders, when it
    ///   has them. Nil means "read `web.*`" — the ordinary case.
    ///
    ///   This used to be a scan: `configure` checked `allRegistrations()` for
    ///   a `WebCoders` an earlier module had registered and stood down if it
    ///   found one, which made the answer depend on module order and on a
    ///   runtime lookup. Whether the application brought its own coders is a
    ///   fact about how it was composed, so it is a parameter — and one the
    ///   composer fills in by type when any module provides `WebCoders`.
    public init(
        configuration: Configuration,
        routes: [RouteRegistration] = [],
        middleware: [MiddlewareRegistration] = [],
        assetMounts: [AssetMountRegistration] = [],
        coders: WebCoders? = nil,
        errorMapper: ErrorMapper? = nil
    ) throws {
        let resolvedCoders = try coders ?? WebCoders(configuration: configuration)
        let resolvedMapper = errorMapper ?? .none
        self.configuration = configuration
        self.coders = resolvedCoders
        self.errorMapper = resolvedMapper
        self.routes = routes
        self.middleware = middleware
        self.assetMounts = assetMounts
        // Dispatch — and route-table validation — is built here, from values.
        // A conflicting or malformed route, or one naming an undeclared lane,
        // fails composition rather than at the service's first breath.
        self.dispatch = try DispatchBuilder.build(
            routes: routes,
            middleware: middleware,
            assetMounts: assetMounts,
            web: WebRuntime(coders: resolvedCoders, errorMapper: resolvedMapper),
            logger: Logger(label: "flight.web"))
    }

    public init() {
        preconditionFailure(
            "FlightWebModule takes its configuration and the application's routes in "
                + "init(configuration:routes:middleware:assetMounts:), so it cannot be "
                + "instantiated from its type. Pass `composedBy: flightComposeModules` to "
                + "Flight.run — `flight new` writes that argument — or construct the module "
                + "yourself and use the entry point taking module instances.")
    }

    public var service: (any Service)? {
        WebHostService<Transport>(dispatch: dispatch, configuration: configuration)
    }

    /// The transport is what brings work in, so it is the first thing to
    /// stop: no new requests, drain what is in flight, and only then let the
    /// pools and buses everything else was using go.
    public var serviceShutdownPhase: ServiceShutdownPhase { .inbound }
}

/// Runs the web stack: read the transport's settings from the app
/// configuration, hand the already-built dispatch to a fresh transport
/// instance, and park in its `run()` until shutdown.
///
/// It used to hold the container and build dispatch here, at `run()`, because
/// the route table was collected from the container post-`freeze()`. The
/// module owns the routes now, so the table is built during configuration and
/// this only runs it.
struct WebHostService<Transport: ServerTransport>: Service {
    let dispatch: Dispatch
    let configuration: Configuration

    func run() async throws {
        let transport = Transport(
            configuration: try Transport.Configuration(configuration: configuration),
            dispatch: dispatch
        )
        try await transport.run()
    }
}
