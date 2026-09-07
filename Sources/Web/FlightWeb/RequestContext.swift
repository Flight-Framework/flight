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

    private let container: Container

    public init(
        request: Request,
        pathParameters: [String: String] = [:],
        identity: RequestIdentity = .anonymous,
        logger: Logger,
        tracingContext: ServiceContext = .topLevel,
        container: Container
    ) {
        self.request = request
        self.pathParameters = pathParameters
        self.identity = identity
        self.logger = logger
        self.tracingContext = tracingContext
        self.container = container
    }

    public func pathParam(_ name: String) -> String? {
        pathParameters[name]
    }

    /// Resolves a component from the application's container.
    ///
    /// A service-locator seam, and on the way out: the composition migration
    /// replaces it with construction in the generated route terminal, where
    /// a controller's dependencies arrive as initializer arguments instead
    /// (COMPOSITION-MIGRATION.md §2.1a). It no longer takes a scope, because
    /// there are no longer any scoped components to resolve.
    public func resolve<T: Sendable>(_ type: T.Type = T.self, qualifier: String? = nil) throws -> T {
        try container.resolve(type, qualifier: qualifier)
    }
}
