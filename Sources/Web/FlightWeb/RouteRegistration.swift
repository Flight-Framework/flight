import FlightCore
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
        /// `Response.upgrade`.
        case upgrade
    }

    public let method: HTTPRequest.Method
    /// The path pattern as written at the mapping site ("/users/:id").
    public let path: String
    public let kind: Kind
    /// Where this route was declared ("UserController.getUser") — carried
    /// for startup logs, conflict diagnostics, and introspection.
    public let source: String
    /// The fully-encoded handler thunk: body decoding and return-value
    /// encoding already applied by the macro expansion.
    public let handler: @Sendable (RequestContext) async throws -> Response

    public init(
        method: HTTPRequest.Method,
        path: String,
        kind: Kind = .http,
        source: String = "<direct>",
        handler: @escaping @Sendable (RequestContext) async throws -> Response
    ) {
        self.method = method
        self.path = path
        self.kind = kind
        self.source = source
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

    public let name: String
    public let order: Int
    let generation: Generation
    let handle: @Sendable (RequestContext, Next) async throws -> Response

    init(
        name: String, order: Int, generation: Generation,
        handle: @escaping @Sendable (RequestContext, Next) async throws -> Response
    ) {
        self.name = name
        self.order = order
        self.generation = generation
        self.handle = handle
    }

    /// Wraps a `Middleware` value directly, for testing a chain — with
    /// `compose(_:around:)` — without a container. A real application
    /// registers through `container.pipeline { }` instead, which resolves
    /// the type through dependency injection; this is the same normalized
    /// shape, just built from a value already in hand.
    public init(_ middleware: any Middleware, name: String? = nil) {
        self.init(
            name: name ?? String(reflecting: type(of: middleware)), order: 0, generation: .pipeline
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

extension Container {
    /// Registers a route by hand — the same escape hatch beside the macro
    /// path that Core's `register` is beside `@Component`. Runs during a
    /// module's `configure(_:)`, i.e. still bootstrap-time: this is not a
    /// runtime route-registration API (§10 non-goal stands).
    public func registerRoute(
        _ method: HTTPRequest.Method,
        _ path: String,
        kind: RouteRegistration.Kind = .http,
        source: String = "<direct>",
        handler: @escaping @Sendable (RequestContext) async throws -> Response
    ) {
        let registration = RouteRegistration(
            method: method, path: path, kind: kind, source: source, handler: handler
        )
        register(
            RouteRegistration.self,
            qualifier: "\(method.rawValue) \(path) @\(source)",
            scope: .singleton
        ) { _ in registration }
    }

    /// Declares which `@Middleware` types run, and in what order — outermost
    /// first. This is the one place order is decided; a `@Middleware` type
    /// that appears nowhere in a `pipeline { }` block is a fully-formed,
    /// independently resolvable and testable component that simply never
    /// runs, which is a one-line fix rather than a silently-wrong answer.
    ///
    /// Calling this more than once composes: a framework module (Flight
    /// Security's authentication, say) can install its own middleware from
    /// its own `configure(_:)`, ahead of whatever the application declares
    /// in its own `pipeline { }` — the two blocks do not have to be one
    /// call, or know about each other. Every entry gets the *same* declared
    /// order regardless of which call or which position within a call it
    /// came from, deliberately: what actually orders them is registration
    /// sequence (`collectMiddleware`'s existing tiebreak), which already
    /// reflects both "which module's `configure` ran first" (the module
    /// DAG — Flight Core §2) and "which type was listed first within one
    /// `pipeline { }` block". A per-call index would get the second part
    /// right and the first part wrong: two separate calls each starting
    /// their own count at zero would interleave by position instead of
    /// concatenating by call, which is not what "Security installs its
    /// middleware, then the app installs its own" means.
    ///
    /// Each type is resolved exactly once, the first time this pipeline is
    /// assembled (post-freeze, before the first request) — the same "compose
    /// once, not per request" property the chain itself already had. This is
    /// why `@Middleware` types are always `.singleton`: a `.scoped` instance
    /// resolved here would be permanently pinned to whichever request scope
    /// happened to trigger that first resolution.
    ///
    /// ```swift
    /// container.pipeline {
    ///     RequestTiming.self
    ///     Transactions.self
    ///     Authentication.self
    /// }
    /// ```
    public func pipeline(@MiddlewarePipelineBuilder _ build: () -> [any Middleware.Type]) {
        for type in build() {
            let name = String(reflecting: type)
            register(MiddlewareRegistration.self, qualifier: "pipeline.\(name)", scope: .singleton) {
                container in
                let instance = try container.resolve(type)
                return MiddlewareRegistration(name: name, order: 0, generation: .pipeline) {
                    context, next in try await instance.handle(context, next: next)
                }
            }
        }
    }

    /// Registers a named middleware from a closure.
    ///
    /// Existing call sites keep compiling: `Middleware` and `Next` were
    /// retargeted to the new protocol-based shape, but this overload's
    /// closure parameter is `ClosureMiddleware` — the old `inout`-based
    /// shape — so an inline closure written against the old signature still
    /// matches it exactly.
    @available(
        *, deprecated,
        message: "Conform a type to Middleware and list it in a container.pipeline { } instead."
    )
    public func registerMiddleware(
        _ name: String,
        order: Int = 0,
        _ middleware: @escaping ClosureMiddleware
    ) {
        register(MiddlewareRegistration.self, qualifier: name, scope: .singleton) { _ in
            MiddlewareRegistration(name: name, order: order, generation: .legacyClosure) {
                context, next in
                var mutableContext = context
                // A legacy closure's `next` cannot see a thrown error — it
                // predates `Next` throwing at all — so anything thrown by an
                // inner layer must already be a `Response` by the time it
                // reaches here, via the same conversion the whole pipeline
                // uses everywhere else.
                let legacyNext: ClosureNext = { innerContext in
                    do {
                        return try await next(innerContext)
                    } catch {
                        return errorResponse(for: error, context: innerContext)
                    }
                }
                return await middleware(&mutableContext, legacyNext)
            }
        }
    }

    /// Registers a request-only step — the deprecated ``MiddlewareResult``
    /// form. Chosen by the closure's arity, exactly as it was before
    /// `Middleware` existed as a protocol.
    @available(
        *, deprecated,
        message: "Conform a type to Middleware and list it in a container.pipeline { } instead."
    )
    public func registerMiddleware(
        _ name: String,
        order: Int = 0,
        _ step: @escaping @Sendable (inout RequestContext) async -> MiddlewareResult
    ) {
        registerMiddleware(name, order: order, middleware(from: step))
    }
}

extension Container {
    /// All route entries, in registration order (post-freeze).
    public func collectRoutes() throws -> [RouteRegistration] {
        try collect(RouteRegistration.self)
    }

    /// All middleware entries: every `pipeline { }` entry first (in the
    /// order declared there), then every deprecated `registerMiddleware`
    /// closure sorted by `(order, registration sequence)` — see
    /// `MiddlewareRegistration.Generation`.
    public func collectMiddleware() throws -> [MiddlewareRegistration] {
        try collect(MiddlewareRegistration.self)
            .enumerated()
            .sorted { ($0.element.generation, $0.element.order, $0.offset) < ($1.element.generation, $1.element.order, $1.offset) }
            .map(\.element)
    }

    /// Resolves every component of `type` via introspection — Core's public
    /// `allRegistrations()` carries (typeName, qualifier), which is exactly
    /// enough to enumerate one type's registrations without any new Core API.
    private func collect<T: Sendable>(_ type: T.Type) throws -> [T] {
        let typeName = String(reflecting: type)
        return try allRegistrations()
            .filter { $0.typeName == typeName }
            .map { try resolve(type, qualifier: $0.qualifier) }
    }
}
