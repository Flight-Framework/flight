import FlightCore
import Logging
import ServiceContextModule

/// Everything a middleware or handler needs about one in-flight request (§2).
///
/// `scope` is `let`, deliberately: a request's scope lifetime is fixed for
/// the duration of that request, and nothing about middleware processing can
/// swap it out mid-flight.
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
    public var response: Response

    /// Opened once per request by Flight Web's dispatch closure — Flight Web
    /// is the first thing to interpret a Scope's lifetime as "one request";
    /// Core never learns this interpretation exists (Flight Core §3).
    ///
    /// Delta note: the scope is created directly rather than through
    /// `Container.withScope`, because streaming and upgrade responses outlive
    /// the dispatch call — the scope ends when the request's last reference
    /// (context, stream, or connection handler) is released.
    public let scope: Scope

    /// Structured logging, present from the very first request this framework
    /// ever handles — dispatch stamps request metadata (request ID, method,
    /// path) before any middleware runs.
    public var logger: Logger

    /// Tracing context for the request's server span; propagated trace
    /// headers are extracted into it by dispatch before any middleware runs.
    public var tracingContext: ServiceContext

    private let container: Container

    public init(
        request: Request,
        pathParameters: [String: String] = [:],
        response: Response = .notFound,
        scope: Scope,
        logger: Logger,
        tracingContext: ServiceContext = .topLevel,
        container: Container
    ) {
        self.request = request
        self.pathParameters = pathParameters
        self.response = response
        self.scope = scope
        self.logger = logger
        self.tracingContext = tracingContext
        self.container = container
    }

    public func pathParam(_ name: String) -> String? {
        pathParameters[name]
    }

    /// Resolves a component against this request's scope. `.scoped` components live
    /// exactly as long as the request; `.singleton`/`.transient` components behave
    /// as they would from any other resolution site (Flight Core §3).
    public func resolve<T: Sendable>(_ type: T.Type = T.self, qualifier: String? = nil) throws -> T {
        try container.resolve(type, qualifier: qualifier, in: scope)
    }
}
