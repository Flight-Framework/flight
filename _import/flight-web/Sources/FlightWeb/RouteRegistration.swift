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

/// A named middleware component plus its position in the chain. Registered
/// through the same pipeline as everything else; collected and sorted by
/// (order, registration sequence) when dispatch is built.
public struct MiddlewareRegistration: Sendable {
    public let name: String
    public let order: Int
    public let middleware: Middleware

    public init(name: String, order: Int = 0, middleware: @escaping Middleware) {
        self.name = name
        self.order = order
        self.middleware = middleware
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

    /// Registers a named middleware. Lower `order` runs earlier; equal orders
    /// keep registration sequence (module DAG order — deterministic).
    public func registerMiddleware(
        _ name: String,
        order: Int = 0,
        _ middleware: @escaping Middleware
    ) {
        register(MiddlewareRegistration.self, qualifier: name, scope: .singleton) { _ in
            MiddlewareRegistration(name: name, order: order, middleware: middleware)
        }
    }

    /// Registers a request-only step — the ``MiddlewareResult`` form.
    ///
    /// Chosen by the closure's arity: a two-parameter closure is a full
    /// ``Middleware`` layer, a one-parameter closure is this. Prefer this one
    /// whenever the layer does not need to see the response, because
    /// `.continue` cannot be forgotten the way a call to `next` can.
    ///
    /// ```swift
    /// container.registerMiddleware("auth", order: -100) { context in
    ///     guard context.request.headers[.authorization] != nil else {
    ///         return .respond(.status(.unauthorized))
    ///     }
    ///     return .continue
    /// }
    /// ```
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

    /// All middleware entries, sorted by (order, registration sequence).
    public func collectMiddleware() throws -> [MiddlewareRegistration] {
        try collect(MiddlewareRegistration.self)
            .enumerated()
            .sorted { ($0.element.order, $0.offset) < ($1.element.order, $1.offset) }
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
