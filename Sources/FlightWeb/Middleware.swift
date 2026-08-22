import HTTPTypes

/// How one middleware step ends (§3): keep going, answer now, or fail —
/// no exception-based control flow, no unwinding through wrapper layers.
public enum MiddlewareResult: Sendable {
    case `continue`
    case respond(Response)
    case fail(any Error)
}

/// One middleware step: a plain async function over the shared context.
/// The flat-array-over-shared-data shape is the deliberate DOD win here
/// (§3, §9) — a sequential loop, not a chain of wrapping objects.
public typealias Middleware = @Sendable (inout RequestContext) async -> MiddlewareResult

/// Runs the chain over one context (§3). Nothing downstream of a `.respond`
/// or `.fail` runs; a chain that completes without answering yields
/// `context.response` (which starts as 404 and is set by the routing
/// middleware at the end of the standard chain).
public func runMiddleware(
    _ chain: [Middleware],
    _ context: inout RequestContext
) async -> Response {
    for middleware in chain {
        switch await middleware(&context) {
        case .continue:
            continue
        case .respond(let response):
            return response
        case .fail(let error):
            return errorResponse(for: error, context: context)
        }
    }
    return context.response
}

/// Maps a thrown/failed error onto the wire (§3):
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
