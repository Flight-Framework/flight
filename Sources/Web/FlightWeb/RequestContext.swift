import FlightCore
import Logging
import ServiceContextModule

/// Everything a middleware or handler needs about one in-flight request (§2).
///
/// Design delta, recorded in README: the doc's sketch has no container
/// reference, but a `Scope` is only usable through
/// `Container.resolve(_:in:)` — so the context carries the container
/// privately and exposes `resolve(_:qualifier:)`, which is what makes
/// request-scoped components reachable from handlers at all. The stored property
/// is not public; handlers still cannot reach registration APIs or anything
/// beyond scoped resolution ergonomics.
public struct RequestContext: Sendable {
    public let request: Request
    public var pathParameters: [String: String]

    /// What authentication decided about this request, written by the
    /// authentication middleware into the copy it passes downstream.
    ///
    /// Flight Web stores it and never reads it: the seam exists so an
    /// identity can ride the request without `RequestContext` depending on
    /// the package that defines one. `.anonymous` until something says
    /// otherwise, so a request through a pipeline with no authentication
    /// behaves exactly as it did before.
    public var identity: RequestIdentity

    /// Structured logging, present from the very first request this framework
    /// ever handles — dispatch stamps request metadata (request ID, method,
    /// path) before any middleware runs.
    public var logger: Logger

    /// Tracing context for the request's server span; propagated trace
    /// headers are extracted into it by dispatch before any middleware runs.
    public var tracingContext: ServiceContext

    /// The application's web runtime — encoders/decoders and error mapper,
    /// identical for every request. Held behind one reference so the context
    /// stays within two cache lines (it is copied per middleware layer); a
    /// hand-built context gets `.default`. Stamped by dispatch from what
    /// `FlightWebModule` was composed with (§2.5), replacing a container
    /// lookup.
    public var web: WebRuntime

    /// This application's encoders/decoders.
    public var coders: WebCoders { web.coders }

    /// This application's error mapper. `.none` declines everything.
    public var errorMapper: ErrorMapper { web.errorMapper }

    public init(
        request: Request,
        pathParameters: [String: String] = [:],
        identity: RequestIdentity = .anonymous,
        logger: Logger,
        tracingContext: ServiceContext = .topLevel,
        web: WebRuntime = .default
    ) {
        self.request = request
        self.pathParameters = pathParameters
        self.identity = identity
        self.logger = logger
        self.tracingContext = tracingContext
        self.web = web
    }

    public func pathParam(_ name: String) -> String? {
        pathParameters[name]
    }
}

/// The per-application web runtime a `RequestContext` carries: coders and the
/// error mapper. One immutable reference, shared across every request, so the
/// context it rides on stays small.
public final class WebRuntime: Sendable {
    public let coders: WebCoders
    public let errorMapper: ErrorMapper

    public init(coders: WebCoders = .default, errorMapper: ErrorMapper = .none) {
        self.coders = coders
        self.errorMapper = errorMapper
    }

    /// Package defaults — what a hand-built context uses.
    public static let `default` = WebRuntime()
}
