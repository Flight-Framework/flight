import FlightCore
import Foundation
import HTTPTypes

/// The "different kind of entry" the shared registration pipeline emits for
/// routes (§4): `@Controller`'s generated `_flightRegister` registers the
/// controller component *and* one `RouteRegistration` component per mapped method,
/// through the very same `Container.register` every other component uses. The web
/// module collects them post-freeze into the route table — no parallel
/// registration mechanism exists, and routes show up in Core introspection
/// (`allRegistrations()`) like any other component.
public struct RouteRegistration: Sendable {
    public enum Kind: Sendable, Equatable {
        /// An ordinary request/response route.
        case http
        /// A connection-upgrade route (§6.1) — the handler must produce
        /// `Response.upgrade`. Carries *which* protocol the connection is
        /// handed to, so the route table knows it statically — this is what
        /// will let bootstrap refuse a route the active transport cannot
        /// serve (a WebTransport route on an HTTP/1.1-only listener) at
        /// freeze rather than as a runtime error on first use.
        case upgrade(UpgradeKind)

        /// Whether this is any upgrade kind — the question the router and
        /// dispatch logging actually ask, which does not care about the
        /// specific protocol.
        public var isUpgrade: Bool {
            if case .upgrade = self { return true }
            return false
        }
    }

    public let method: HTTPRequest.Method
    /// The path pattern as written at the mapping site ("/users/:id").
    public let path: String
    public let kind: Kind
    /// Where this route was declared ("UserController.getUser") — carried
    /// for startup logs, conflict diagnostics, and introspection.
    public let source: String
    /// Which middleware lanes wrap this route, in order — the names of
    /// `container.pipeline("name") { }` declarations, concatenated. The
    /// default is the unnamed default lane, so every route behaves exactly
    /// as before lanes existed unless it says otherwise. Referencing a lane
    /// nobody declared fails when dispatch is built — bootstrap, not the
    /// first request.
    public let pipelines: [PipelineLane]

    /// How the transport delivers this route's body — asked from the route
    /// table before any bytes are read, exactly like `acceptsUpgrade`.
    public enum BodyMode: Sendable, Equatable {
        /// Collected whole before dispatch (the default). `maxBytes` nil
        /// means the transport's global cap.
        case buffered(maxBytes: Int?)
        /// Delivered live via ``RequestBodyStream`` — what a handler with a
        /// `body: RequestBodyStream` parameter gets, recorded here by the
        /// macro. `maxBytes` caps the cumulative stream (nil: the global
        /// cap), enforced by the transport as bytes arrive.
        case streaming(maxBytes: Int?)
    }
    public let bodyMode: BodyMode

    /// The fully-encoded handler thunk: body decoding and return-value
    /// encoding already applied by the macro expansion.
    public let handler: @Sendable (RequestContext) async throws -> Response

    public init(
        method: HTTPRequest.Method,
        path: String,
        kind: Kind = .http,
        source: String = "<direct>",
        pipelines: [PipelineLane] = [.default],
        bodyMode: BodyMode = .buffered(maxBytes: nil),
        handler: @escaping @Sendable (RequestContext) async throws -> Response
    ) {
        self.method = method
        self.path = path
        self.kind = kind
        self.source = source
        self.pipelines = pipelines
        self.bodyMode = bodyMode
        self.handler = handler
    }
}

/// A named middleware layer plus its position in the chain, normalized to
/// one canonical shape regardless of whether it came from `@Middleware` +
/// `container.pipeline { }` or a deprecated `registerMiddleware` closure.
/// Registered through the same pipeline as everything else; collected and
/// sorted when dispatch is built.
public struct MiddlewareRegistration: Sendable {
    /// `pipeline`-declared layers always run outermost, ahead of every
    /// `registerMiddleware` closure, regardless of what numeric `order` the
    /// closures used — this is what lets a migration move one closure at a
    /// time into `pipeline { }` without renumbering everything else already
    /// there. Within a generation, entries sort by `(order, sequence)`.
    enum Generation: Int, Sendable, Comparable {
        case pipeline = 0
        case legacyClosure = 1
        static func < (lhs: Generation, rhs: Generation) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// The lane every route runs through unless it names others — and the
    /// one `container.pipeline { }` (no name) feeds. Spelled
    /// ``PipelineLane/default`` at a declaration site; kept here because
    /// this is where the chain-assembly code reaches for it.
    public static let defaultLane = PipelineLane.default

    public let name: String
    /// Which named lane this layer belongs to.
    public let lane: PipelineLane
    public let order: Int
    let generation: Generation
    /// A placeholder recording that a lane was declared, carrying no
    /// behavior. `pipeline(_:_:)` registers one per named lane so that a
    /// lane with no middleware in it still *exists* — the empty
    /// static-asset lane is the motivating case, and the undeclared-lane
    /// error already promised it was legal. Filtered out of
    /// `collectMiddleware(lane:)`, so it costs a request nothing.
    let isLaneMarker: Bool
    let handle: @Sendable (RequestContext, Next) async throws -> Response

    init(
        name: String, lane: PipelineLane, order: Int, generation: Generation,
        isLaneMarker: Bool = false,
        handle: @escaping @Sendable (RequestContext, Next) async throws -> Response
    ) {
        self.name = name
        self.lane = lane
        self.order = order
        self.generation = generation
        self.isLaneMarker = isLaneMarker
        self.handle = handle
    }

    /// Wraps a `Middleware` value directly, for testing a chain — with
    /// `compose(_:around:)` — without a container. A real application
    /// registers through `container.pipeline { }` instead, which resolves
    /// the type through dependency injection; this is the same normalized
    /// shape, just built from a value already in hand.
    public init(_ middleware: any Middleware, name: String? = nil) {
        self.init(
            name: name ?? String(reflecting: type(of: middleware)),
            lane: Self.defaultLane, order: 0, generation: .pipeline
        ) { context, next in
            try await middleware.handle(context, next: next)
        }
    }
}

/// The order `container.pipeline { }` declares — outermost first, one entry
/// per `@Middleware` type.
@resultBuilder
public enum MiddlewarePipelineBuilder {
    public static func buildBlock(_ types: any Middleware.Type...) -> [any Middleware.Type] {
        types
    }
}

extension MiddlewareRegistration {
    /// One lane's worth of middleware, as values — the value-level spelling of
    /// `container.pipeline(name) { ... }`.
    ///
    /// A module that owns its middleware has the *instances*, so there is
    /// nothing to resolve: the container form exists because a registration
    /// could only name a type and resolve it later. The lane marker comes
    /// first for the same reason it does there — a lane with no middleware is
    /// still a declared lane, and a route naming it must validate.
    public static func lane(
        _ name: PipelineLane, _ middleware: [any Middleware]
    ) -> [MiddlewareRegistration] {
        var registrations = [
            MiddlewareRegistration(
                name: "__lane", lane: name, order: 0, generation: .pipeline,
                isLaneMarker: true
            ) { context, next in try await next(context) }
        ]
        for instance in middleware {
            registrations.append(
                MiddlewareRegistration(
                    name: String(reflecting: type(of: instance)), lane: name, order: 0,
                    generation: .pipeline
                ) { context, next in try await instance.handle(context, next: next) })
        }
        return registrations
    }
}


