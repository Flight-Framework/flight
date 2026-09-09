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
    private var dispatch: Dispatch?

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
        self.configuration = configuration
        self.coders = try coders ?? WebCoders(configuration: configuration)
        self.errorMapper = errorMapper ?? .none
        self.routes = routes
        self.middleware = middleware
        self.assetMounts = assetMounts
    }

    /// This module takes what it provides, so it cannot be built from its
    /// type — every supported path checks this and throws first.
    public static var isTypeConstructible: Bool { false }

    public init() {
        preconditionFailure(
            "FlightWebModule takes its configuration and the application's routes in "
                + "init(configuration:routes:middleware:assetMounts:), so it cannot be "
                + "instantiated from its type. Pass `composedBy: flightComposeModules` to "
                + "Flight.run — `flight new` writes that argument — or construct the module "
                + "yourself and use the entry point taking module instances.")
    }

    public func configure(_ container: Container) throws {
        let coders = self.coders
        let errorMapper = self.errorMapper
        container.register(WebCoders.self, scope: .singleton) { _ in coders }
        container.register(ErrorMapper.self, scope: .singleton) { _ in errorMapper }

        // Route-table validation happens here now — a conflicting or malformed
        // route, or one naming an undeclared lane, fails during module
        // configuration rather than at the service's first breath. Earlier,
        // and at the point that assembled the table.
        let dispatch = try DispatchBuilder.build(
            routes: routes,
            middleware: middleware,
            assetMounts: assetMounts,
            web: WebRuntime(coders: coders, errorMapper: errorMapper),
            logger: Logger(label: "flight.web"))
        self.dispatch = dispatch
        container.register(Dispatch.self, scope: .singleton) { _ in dispatch }

        // Registered for *introspection*, not for dispatch — the table above
        // is already built. Actuator's dashboard lists routes through the same
        // `allRegistrations()` it lists everything else through, and a route
        // that only existed as a value would have vanished from it.
        for route in routes {
            container.register(
                RouteRegistration.self,
                qualifier: "\(route.method.rawValue) \(route.path) @\(route.source)",
                scope: .singleton
            ) { _ in route }
        }
    }

    public var service: (any Service)? {
        dispatch.map {
            WebHostService<Transport>(dispatch: $0, configuration: configuration)
        }
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
