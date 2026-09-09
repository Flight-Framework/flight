import FlightCore
import Foundation
import HTTPTypes

/// One mapped route, as a value (§4). `@Controller` generates one route
/// *factory* per mapped method; the composition root's `flightRoutes(_:)`
/// calls them and hands the resulting `RouteRegistration` values to
/// `FlightWebModule`, which builds them into the route table when its dispatch
/// is assembled. A hand-written route is the same value — there is no separate
/// registration mechanism.
public struct RouteRegistration: Sendable {
    public enum Kind: Sendable, Equatable {
        /// An ordinary request/response route.
        case http
        /// A connection-upgrade route (§6.1) — the handler must produce
        /// `Response.upgrade`. Carries *which* protocol the connection is
        /// handed to, so the route table knows it statically — this is what
        /// will let bootstrap refuse a route the active transport cannot
        /// serve (a WebTransport route on an HTTP/1.1-only listener) at
        /// composition rather than as a runtime error on first use.
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
    /// `MiddlewareRegistration.lane("name", [...])` declarations, concatenated. The
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

/// A named middleware layer plus the lane it belongs to. A module declares
/// these with `MiddlewareRegistration.lane(_:_:)`; the composition root gathers
/// them, and dispatch assembles each lane's layers into a chain in declaration
/// order, outermost first.
public struct MiddlewareRegistration: Sendable {

    /// The lane every route runs through unless it names others — the one
    /// `MiddlewareRegistration.lane(.default, [...])` feeds. Spelled
    /// ``PipelineLane/default`` at a declaration site; kept here because
    /// this is where the chain-assembly code reaches for it.
    public static let defaultLane = PipelineLane.default

    public let name: String
    /// Which named lane this layer belongs to.
    public let lane: PipelineLane
    /// A placeholder recording that a lane was declared, carrying no
    /// behavior. `MiddlewareRegistration.lane(_:_:)` puts one first per lane
    /// so that a lane with no middleware in it still *exists* — the empty
    /// static-asset lane is the motivating case, and the undeclared-lane
    /// error already promised it was legal. Filtered out when the lane's chain
    /// is assembled, so it costs a request nothing.
    let isLaneMarker: Bool
    let handle: @Sendable (RequestContext, Next) async throws -> Response

    init(
        name: String, lane: PipelineLane,
        isLaneMarker: Bool = false,
        handle: @escaping @Sendable (RequestContext, Next) async throws -> Response
    ) {
        self.name = name
        self.lane = lane
        self.isLaneMarker = isLaneMarker
        self.handle = handle
    }

    /// Wraps a `Middleware` value directly, for testing a chain — with
    /// `compose(_:around:)` — in isolation. A real application declares its
    /// middleware through `MiddlewareRegistration.lane(_:_:)` instead; this is
    /// the same normalized shape, just built from a single value in hand.
    public init(_ middleware: any Middleware, name: String? = nil) {
        self.init(
            name: name ?? String(reflecting: type(of: middleware)),
            lane: Self.defaultLane
        ) { context, next in
            try await middleware.handle(context, next: next)
        }
    }
}

extension MiddlewareRegistration {
    /// One lane's worth of middleware, as values — the value-level spelling of
    /// what `container.pipeline(name) { ... }` used to declare.
    ///
    /// A module that owns its middleware has the *instances*, so there is
    /// nothing to resolve: the container form existed because a registration
    /// could only name a type and resolve it later. The lane marker comes
    /// first for the same reason it did there — a lane with no middleware is
    /// still a declared lane, and a route naming it must validate.
    public static func lane(
        _ name: PipelineLane, _ middleware: [any Middleware]
    ) -> [MiddlewareRegistration] {
        var registrations = [
            MiddlewareRegistration(
                name: "__lane", lane: name, isLaneMarker: true
            ) { context, next in try await next(context) }
        ]
        for instance in middleware {
            registrations.append(
                MiddlewareRegistration(
                    name: String(reflecting: type(of: instance)), lane: name
                ) { context, next in try await instance.handle(context, next: next) })
        }
        return registrations
    }
}


