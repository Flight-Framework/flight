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

    /// Post-freeze only: routes and middleware are components, and components exist to
    /// be read once the container is frozen (Flight Core §2.1).
    public static func build(
        container: Container,
        logger: Logger = Logger(label: "flight.web")
    ) throws -> Dispatch {
        precondition(
            container.isFrozen,
            "DispatchBuilder.build requires a frozen container — routes are components, collected post-freeze."
        )
        let router = try Router(routes: container.collectRoutes())
        let userMiddleware = try container.collectMiddleware()

        for route in router.routes {
            logger.debug("route registered", metadata: [
                "method": "\(route.method.rawValue)",
                "path": "\(route.path)",
                "kind": route.kind == .upgrade ? "upgrade" : "http",
                "source": "\(route.source)",
            ])
        }
        logger.info("flight web dispatch assembled", metadata: [
            "routes": .stringConvertible(router.routes.count),
            "middleware": .array(userMiddleware.map { .string($0.name) }),
        ])

        return makeDispatch(
            chain: userMiddleware.map(\.middleware),
            responder: router.responder,
            acceptsUpgrade: { router.acceptsUpgrade(method: $0.method, path: $0.path) },
            container: container,
            logger: logger)
    }

    /// The assembled per-request pipeline, exposed separately so test
    /// harnesses can run a hand-built chain without a container full of
    /// controller components.
    ///
    /// `chain` is folded around `responder` **once, here** — a request pays
    /// one call per layer, never the cost of building the chain.
    public static func makeDispatch(
        chain: [Middleware],
        responder: @escaping Next,
        acceptsUpgrade: @escaping @Sendable (Request) -> Bool = { _ in false },
        container: Container,
        logger: Logger
    ) -> Dispatch {
        let pipeline = compose(chain, around: responder)
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
                var context = RequestContext(
                    request: request,
                    scope: Scope(),
                    logger: requestLogger,
                    tracingContext: span.context,
                    container: container
                )
                let response = await pipeline(&context)

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
