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
/// A class, because it stashes the container during `configure` for the
/// service to build dispatch from later, post-freeze — the same shape as any
/// service-owning module (Flight Core §4).
public final class FlightWebModule<Transport: ServerTransport>: FlightModule {
    private var container: Container?

    public init() {}

    public func configure(_ container: Container) throws {
        self.container = container

        // Registration and resolution are separate phases, so the coders are
        // *registered* here and *built* at freeze — reading configuration now
        // would trip Core's "resolution begins at freeze()" precondition.
        //
        // Checked against the registration list rather than by resolving, for
        // the same reason. An application that registers its own `WebCoders`
        // in a module configured before this one keeps it; registering both
        // would be a duplicate-registration failure, not a silent override.
        let alreadyRegistered = container.allRegistrations().contains {
            $0.typeName == String(reflecting: WebCoders.self) && $0.qualifier == nil
        }
        guard !alreadyRegistered else { return }

        container.register(WebCoders.self, scope: .singleton) { c in
            try WebCoders(configuration: c.resolve(Configuration.self))
        }
    }

    public var service: (any Service)? {
        container.map { WebHostService<Transport>(container: $0) }
    }
}

/// Runs the web stack: build dispatch from the (by now frozen) container,
/// read the transport's settings from the app configuration, hand dispatch
/// to a fresh transport instance, and park in its `run()` until shutdown.
struct WebHostService<Transport: ServerTransport>: Service {
    let container: Container

    func run() async throws {
        let logger = Logger(label: "flight.web")
        // Route-table validation happens here, at startup: a conflicting or
        // malformed route fails the app before the socket ever binds.
        let dispatch = try DispatchBuilder.build(container: container, logger: logger)
        // Force the coders now. They are registered lazily, so without this a
        // misspelled `web.json.date-strategy` would first surface on whichever
        // request happened to encode something — long after the deploy that
        // introduced it looked successful.
        _ = try container.resolve(WebCoders.self)
        let appConfiguration = try container.resolve(FlightCore.Configuration.self)
        let transport = Transport(
            configuration: try Transport.Configuration(configuration: appConfiguration),
            dispatch: dispatch
        )
        try await transport.run()
    }
}
