import HTTPTypes

/// The rest of the pipeline, as seen from inside a middleware: call it to
/// continue, or don't, to answer without ever reaching the handler.
///
/// Calling this more than once runs the remaining chain more than once —
/// including the handler. That is occasionally what you want (a retry) and
/// usually a bug; the request is a value, so nothing stops you either way.
public typealias Next = @Sendable (inout RequestContext) async -> Response

/// One middleware layer: it receives the request context and the rest of the
/// pipeline, and returns the response.
///
/// The shape is an *onion* — each layer wraps the next, so a layer runs code
/// before the handler, after it, or around it:
///
/// ```swift
/// container.registerMiddleware("timing") { context, next in
///     let started = ContinuousClock.now
///     let response = await next(&context)
///     context.logger.info("\(response.status.code) in \(started.duration(to: .now))")
///     return response
/// }
/// ```
///
/// Wrapping is the capability a flat pre-handler chain cannot provide. It is
/// what lets a middleware hold something open across the handler — a task
/// local, a span, a lock, a transaction — because the handler runs *inside*
/// the layer's own scope:
///
/// ```swift
/// container.registerMiddleware("tenant") { context, next in
///     await Tenant.$current.withValue(tenant(for: context.request)) {
///         await next(&context)
///     }
/// }
/// ```
///
/// **Forgetting to call `next` silently drops the request** — the layer
/// becomes the whole pipeline and no handler runs. When a layer only needs to
/// inspect the request and either continue or answer, prefer the
/// ``MiddlewareResult`` form, where continuing is a value you return rather
/// than a call you must remember to make.
public typealias Middleware = @Sendable (inout RequestContext, Next) async -> Response

/// How a request-only middleware step ends: keep going, answer now, or fail.
///
/// This is the safe subset of ``Middleware`` for layers that never need to see
/// the response — authentication, rejection, request rewriting. `continue`
/// cannot be forgotten the way a call to `next` can.
public enum MiddlewareResult: Sendable {
    case `continue`
    case respond(Response)
    case fail(any Error)
}

/// Adapts a request-only step into a full middleware layer.
///
/// `.continue` calls the rest of the pipeline; `.respond` and `.fail` answer
/// without it. Registration takes this conversion automatically, so a
/// `MiddlewareResult`-returning closure can be registered directly.
public func middleware(
    from step: @escaping @Sendable (inout RequestContext) async -> MiddlewareResult
) -> Middleware {
    { context, next in
        switch await step(&context) {
        case .continue:
            return await next(&context)
        case .respond(let response):
            return response
        case .fail(let error):
            return errorResponse(for: error, context: context)
        }
    }
}

/// Folds a chain of layers around `responder`, outermost first.
///
/// Composition happens **once**, when the dispatch closure is assembled — not
/// per request. What a request pays is one call per layer, not the
/// construction of the chain.
public func compose(_ chain: [Middleware], around responder: @escaping Next) -> Next {
    chain.reversed().reduce(responder) { next, layer in
        { context in await layer(&context, next) }
    }
}

/// Maps a thrown/failed error onto the wire:
/// - `HTTPErrorRepresentable` renders its own status and message;
/// - everything else is an opaque 500 — details go to `context.logger`,
///   never to the client.
public func errorResponse(for error: any Error, context: RequestContext) -> Response {
    switch error {
    case let routing as RoutingError:
        context.logger.error("request failed: \(routing.logDescription)")
        return .problem(status: routing.httpStatus, message: routing.httpMessage)
    case let http as HTTPErrorRepresentable:
        if http.httpStatus.kind == .serverError {
            context.logger.error("request failed: \(String(describing: error))")
        }
        return .problem(status: http.httpStatus, message: http.httpMessage)
    default:
        context.logger.error("unhandled error: \(String(describing: error))")
        return .problem(status: .internalServerError, message: "Internal Server Error")
    }
}
