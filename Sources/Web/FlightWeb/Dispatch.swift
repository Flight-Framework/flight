import FlightCore
import Foundation
import HTTPTypes
import Instrumentation
import Logging
import ServiceContextModule
import Tracing

/// The transport boundary: requests in, responses out — including streaming
/// and upgrade responses. Structured `async` end to end; no `EventLoopFuture`
/// anywhere in this boundary.
///
/// Two operations, not one. `respond` answers a request. ``acceptsUpgrade``
/// asks whether a path is a connection-upgrade route, from the route table
/// alone, and a transport **must** ask it before dispatching an
/// upgrade-shaped request — see that property for why.
public struct Dispatch: Sendable {
    /// Runs the full pipeline: middleware, routing, handler.
    public let respond: @Sendable (Request) async -> Response

    /// Whether this request's method and path resolve to an upgrade route.
    ///
    /// Answered without running anything. A transport that skips this check
    /// and dispatches every upgrade-shaped request will execute ordinary HTTP
    /// handlers — their database writes, their side effects — and then throw
    /// the response away, because it cannot perform an upgrade the route
    /// never offered. That turns any `GET` route into something an
    /// unauthenticated client can trigger by attaching upgrade headers.
    public let acceptsUpgrade: @Sendable (Request) -> Bool

    public init(
        respond: @escaping @Sendable (Request) async -> Response,
        acceptsUpgrade: @escaping @Sendable (Request) -> Bool
    ) {
        self.respond = respond
        self.acceptsUpgrade = acceptsUpgrade
    }

    /// Keeps `await dispatch(request)` reading as a call.
    public func callAsFunction(_ request: Request) async -> Response {
        await respond(request)
    }
}

/// Builds the dispatch closure Flight Web hands to whichever
/// `ServerTransport` is active (§5.3): collect routes and middleware from
/// the frozen container, validate the route table, and wrap the whole §3
/// pipeline — scope-per-request, request-stamped logger, trace extraction
/// and a server span — around it. The transport never sees any of this.
public enum DispatchBuilder {

    /// A route names a middleware lane nobody declared. Bootstrap-time,
    /// deliberately: the alternative is a route that 500s (or silently runs
    /// with the wrong stack) on its first request.
    public struct UndeclaredLaneError: Error, CustomStringConvertible {
        public let lane: String
        public let route: String
        public var description: String {
            "Route \(route) runs through pipeline lane '\(lane)', but no container.pipeline(\"\(lane)\") { } declared it. Declare the lane (an empty block is legal), or remove it from the route's pipelines."
        }
    }

    /// Post-freeze only: routes and middleware are components, and components exist to
    /// be read once the container is frozen (Flight Core §2.1).
    ///
    /// Dispatch routes **first**, then runs the matched route's own lane
    /// chain — composed once per route, here, not per request. That
    /// ordering, rather than one global chain wrapping the router, is what
    /// makes per-route lanes possible: a static-asset route can run a
    /// near-empty stack while its neighbor runs transactions and auth,
    /// because by the time middleware runs the route is already known.
    /// The no-match path (404/405) runs the **default** lane, so access
    /// logging and friends still see every miss — the property the old
    /// wrap-the-router shape had, kept on purpose.
    public static func build(
        container: Container,
        logger: Logger = Logger(label: "flight.web")
    ) throws -> Dispatch {
        precondition(
            container.isFrozen,
            "DispatchBuilder.build requires a frozen container — routes are components, collected post-freeze."
        )
        let router = try Router(routes: container.collectRoutes())

        // Lane validation: the default lane exists even when empty (an app
        // with no middleware is legal); anything else must be declared.
        let declaredLanes = try container.declaredMiddlewareLanes()
        var chainsByLane: [String: [MiddlewareRegistration]] = [:]
        for lane in declaredLanes {
            chainsByLane[lane] = try container.collectMiddleware(lane: lane)
        }
        if chainsByLane[MiddlewareRegistration.defaultLane] == nil {
            chainsByLane[MiddlewareRegistration.defaultLane] = []
        }

        // One composed responder per route, keyed by the same string that is
        // already that route's unique component qualifier.
        var respondersByRoute: [String: Next] = [:]
        for route in router.routes {
            var chain: [MiddlewareRegistration] = []
            for lane in route.pipelines {
                guard let laneChain = chainsByLane[lane] else {
                    throw UndeclaredLaneError(
                        lane: lane, route: "\(route.method.rawValue) \(route.path) (\(route.source))")
                }
                chain += laneChain
            }
            let terminal: Next = { context in
                // Re-match to bind path parameters: the routed outcome that
                // selected this responder is not threaded through, and one
                // extra table lookup per request is cheaper than widening
                // every middleware signature to carry the match.
                guard
                    case .matched(let match) = router.route(
                        method: context.request.method, path: context.request.path)
                else {
                    return context.coders.renderError(.notFound, "Not Found")
                }
                return await Router.execute(match, context: context)
            }
            respondersByRoute[routeKey(route)] = compose(chain, around: terminal)

            logger.debug("route registered", metadata: [
                "method": "\(route.method.rawValue)",
                "path": "\(route.path)",
                "kind": route.kind.isUpgrade ? "upgrade" : "http",
                "pipelines": .array(route.pipelines.map { .string($0) }),
                "source": "\(route.source)",
            ])
        }

        let defaultChain = chainsByLane[MiddlewareRegistration.defaultLane] ?? []
        let noMatchResponder: Next = compose(
            defaultChain,
            around: { context in
                Router.renderNoMatch(
                    router.route(method: context.request.method, path: context.request.path),
                    context: context)
            })

        logger.info("flight web dispatch assembled", metadata: [
            "routes": .stringConvertible(router.routes.count),
            "lanes": .dictionary(
                chainsByLane.mapValues { .array($0.map { .string($0.name) }) }),
        ])

        let responders = respondersByRoute
        let respond: Next = { context in
            switch router.route(method: context.request.method, path: context.request.path) {
            case .matched(let match):
                if let responder = responders[routeKey(match.route)] {
                    return try await responder(context)
                }
                // Unreachable: every route in the table got a responder
                // above. The fallback keeps this total rather than trapping.
                return await Router.execute(match, context: context)
            case .notFound, .methodNotAllowed:
                return try await noMatchResponder(context)
            }
        }

        return makeDispatch(
            pipeline: respond,
            acceptsUpgrade: { router.acceptsUpgrade(method: $0.method, path: $0.path) },
            container: container,
            logger: logger)
    }

    private static func routeKey(_ route: RouteRegistration) -> String {
        "\(route.method.rawValue) \(route.path) @\(route.source)"
    }

    /// The assembled per-request pipeline, exposed separately so test
    /// harnesses can run a hand-built chain — via `collectMiddleware()` on a
    /// container that never has a single controller in it — without needing
    /// a full application's worth of components.
    ///
    /// `chain` is folded around `responder` **once, here** — a request pays
    /// one call per layer, never the cost of building the chain.
    public static func makeDispatch(
        chain: [MiddlewareRegistration],
        responder: @escaping Next,
        acceptsUpgrade: @escaping @Sendable (Request) -> Bool = { _ in false },
        container: Container,
        logger: Logger
    ) -> Dispatch {
        makeDispatch(
            pipeline: compose(chain, around: responder),
            acceptsUpgrade: acceptsUpgrade, container: container, logger: logger)
    }

    /// The per-request envelope — request id, trace extraction, the server
    /// span, one `Scope` — around an already-assembled pipeline.
    public static func makeDispatch(
        pipeline: @escaping Next,
        acceptsUpgrade: @escaping @Sendable (Request) -> Bool = { _ in false },
        container: Container,
        logger: Logger
    ) -> Dispatch {
        let respond: @Sendable (Request) async -> Response = { request in
            // Request identity: honor an inbound X-Request-ID, mint otherwise.
            let requestID = request.headers[.xRequestID] ?? UUID().uuidString

            var requestLogger = logger
            requestLogger[metadataKey: "request-id"] = "\(requestID)"
            requestLogger[metadataKey: "method"] = "\(request.method.rawValue)"
            requestLogger[metadataKey: "path"] = "\(request.path)"

            // Propagated trace context (W3C traceparent etc.) comes in via
            // whatever Instrument the app bootstrapped at its composition
            // root — Flight Web only speaks the facade (Flight Core §9).
            var serviceContext = ServiceContext.topLevel
            InstrumentationSystem.instrument.extract(
                request.headers, into: &serviceContext, using: HTTPFieldsExtractor()
            )

            return await withSpan(
                "HTTP \(request.method.rawValue)",
                context: serviceContext,
                ofKind: .server
            ) { span in
                span.attributes["http.request.method"] = request.method.rawValue
                span.attributes["url.path"] = request.path

                // One Scope per request (§2): created directly, ends when the
                // request's last reference drops — streaming bodies and
                // upgraded connections legitimately outlive this closure.
                let context = RequestContext(
                    request: request,
                    scope: Scope(),
                    logger: requestLogger,
                    tracingContext: span.context,
                    container: container
                )
                // The backstop: a route handler's own thrown errors are
                // already turned into a response inside the router (the
                // innermost layer), so only a middleware throwing — a
                // transaction coordinator failing to bind, a pool exhausted
                // before a handler ever runs — reaches here uncaught.
                let response: Response
                do {
                    response = try await pipeline(context)
                } catch {
                    response = errorResponse(for: error, context: context)
                }

                span.attributes["http.response.status_code"] = response.status.code
                if response.status.kind == .serverError {
                    span.setStatus(SpanStatus(code: .error))
                }
                return response.settingHeader(.xRequestID, requestID)
            }
        }
        return Dispatch(respond: respond, acceptsUpgrade: acceptsUpgrade)
    }
}

extension HTTPField.Name {
    /// Not one of HTTPTypes' predefined names; "X-Request-ID" is valid by
    /// construction.
    public static let xRequestID = HTTPField.Name("X-Request-ID")!
}

/// Reads propagation headers out of `HTTPFields` for trace extraction.
struct HTTPFieldsExtractor: Extractor {
    func extract(key: String, from carrier: HTTPFields) -> String? {
        guard let name = HTTPField.Name(key) else { return nil }
        return carrier[name]
    }
}
