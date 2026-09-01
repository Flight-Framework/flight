import HTTPTypes

/// The rest of the pipeline, as seen from inside a middleware: call it to
/// continue, or don't, to answer without ever reaching the handler.
///
/// A plain value in, a value out — no `inout`. Nothing a middleware needs to
/// hand downstream depends on mutating this parameter in place: per-request
/// state that must be visible across the whole chain already goes through
/// `context.scope` (a reference type shared by every copy of the context for
/// one request), the same channel `PrincipalHolder` and `@Transactional`
/// already use. That is what makes wrapping `next` — holding something open
/// across the handler, the capability a flat pre-handler chain cannot offer
/// — a single expression instead of a copy-out/copy-back dance:
///
/// ```swift
/// struct Tenant: Middleware {
///     func handle(_ context: RequestContext, next: Next) async throws -> Response {
///         try await Tenant.$current.withValue(tenant(for: context.request)) {
///             try await next(context)
///         }
///     }
/// }
/// ```
///
/// Calling this more than once runs the remaining chain more than once —
/// including the handler. That is occasionally what you want (a retry) and
/// usually a bug; the request is a value, so nothing stops you either way.
///
/// Throwing propagates outward through every enclosing layer exactly like a
/// normal Swift call — a layer that wants to observe or decorate an inner
/// failure wraps the call in `do`/`catch`; a layer with nothing to add just
/// lets it through. Nothing escapes the pipeline unconverted: `Dispatch`'s
/// own outermost catch is the backstop, using the same `errorResponse` every
/// layer can reach for directly.
public typealias Next = @Sendable (RequestContext) async throws -> Response

/// A middleware layer, as a type rather than a closure.
///
/// ```swift
/// @Middleware
/// struct RequestTiming {
///     func handle(_ context: RequestContext, next: Next) async throws -> Response {
///         let started = ContinuousClock.now
///         let response = try await next(context)
///         context.logger.info("\(response.status.code) in \(started.duration(to: .now))")
///         return response
///     }
/// }
/// ```
///
/// `@Middleware` registers the type as an ordinary singleton component —
/// resolvable with `@Inject`, constructible and testable on its own, its
/// dependencies and settings arriving through its initializer the same way
/// any other component's do. It does **not** enroll the type in any
/// pipeline: a `@Middleware` type that appears in no `container.pipeline { }`
/// simply never runs, which is a one-line fix rather than the wrong answer
/// shipping silently.
///
/// Order is declared once, in one place, top to bottom — outermost first —
/// rather than as a number attached to each type in isolation:
///
/// ```swift
/// container.pipeline {
///     RequestTiming.self
///     Authentication.self
/// }
/// ```
///
/// A type conforms directly rather than being adapted from a closure:
/// nothing here corresponds to the old `MiddlewareResult` shape, because a
/// type that only needs to inspect the request and continue-or-answer can
/// just not call `next` on the paths that answer early — there is no
/// closure-arity ambiguity to resolve, the way there was between the two
/// deprecated `registerMiddleware` overloads.
public protocol Middleware: Sendable {
    func handle(_ context: RequestContext, next: Next) async throws -> Response
}

/// Folds a chain of layers around `responder`, outermost first.
///
/// Composition happens **once**, when the dispatch closure is assembled — not
/// per request. What a request pays is one call per layer, not the
/// construction of the chain.
public func compose(_ chain: [MiddlewareRegistration], around responder: @escaping Next) -> Next {
    chain.reversed().reduce(responder) { next, registration in
        { context in try await registration.handle(context, next) }
    }
}

/// Maps a thrown/failed error onto the wire:
/// - `HTTPErrorRepresentable` renders its own status and message;
/// - everything else is an opaque 500 — details go to `context.logger`,
///   never to the client.
public func errorResponse(for error: any Error, context: RequestContext) -> Response {
    let render = context.coders.renderError
    switch error {
    case let routing as RoutingError:
        context.logger.error("request failed: \(routing.logDescription)")
        return render(routing.httpStatus, routing.httpMessage)
    case let http as HTTPErrorRepresentable:
        if http.httpStatus.kind == .serverError {
            context.logger.error("request failed: \(String(describing: error))")
        }
        return render(http.httpStatus, http.httpMessage)
    default:
        context.logger.error("unhandled error: \(String(describing: error))")
        return render(.internalServerError, "Internal Server Error")
    }
}

// MARK: - Deprecated closure-based middleware

/// The pre-`@Middleware` shape of `Next`. `inout` is what forced every
/// closure written against it to copy the context out before calling `next`
/// and copy it back after — the ceremony `Middleware`'s plain value-in,
/// value-out shape exists to remove.
@available(
    *, deprecated,
    message: "Conform a type to Middleware and list it in a container.pipeline { } instead."
)
public typealias ClosureNext = @Sendable (inout RequestContext) async -> Response

/// The pre-`@Middleware` shape of a middleware layer. Existing
/// `container.registerMiddleware(name:order:) { context, next in ... }` call
/// sites keep compiling unchanged against this — only the names `Middleware`
/// and `Next` were freed up for the new protocol-based shape.
@available(
    *, deprecated,
    message: "Conform a type to Middleware and list it in a container.pipeline { } instead."
)
public typealias ClosureMiddleware = @Sendable (inout RequestContext, ClosureNext) async -> Response

/// How a request-only middleware step ends: keep going, answer now, or fail.
///
/// This was the safe subset of the closure-based `ClosureMiddleware` for
/// layers that never need to see the response. A `Middleware` conformer has
/// no equivalent need for it: a type that only inspects the request and
/// continues-or-answers just does not call `next` on the paths that answer.
@available(*, deprecated, message: "Return early from Middleware.handle instead of returning .respond/.fail.")
public enum MiddlewareResult: Sendable {
    case `continue`
    case respond(Response)
    case fail(any Error)
}

/// Adapts a request-only step into a full closure-based middleware layer.
@available(
    *, deprecated,
    message: "Conform a type to Middleware and list it in a container.pipeline { } instead."
)
public func middleware(
    from step: @escaping @Sendable (inout RequestContext) async -> MiddlewareResult
) -> ClosureMiddleware {
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
