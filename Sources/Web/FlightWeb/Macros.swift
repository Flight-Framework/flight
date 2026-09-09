import FlightCore

/// Marks a type as a routing controller (§4). Expands like `@Component`
/// (Flight Core §5.1) — a parameterized initializer over its
/// `@Inject`/`@ConfigValue` properties — plus one route *factory* per
/// `@GetRoute`/`@PostRoute`/… method, each of which builds the controller and
/// runs one method as a `RouteRegistration` value.
///
/// The build plugin (Flight Core's `FlightRegistrationPlugin`) picks
/// `@Controller` types up in the same source-scanning pass as `@Component`,
/// so the generated composition root's `flightRoutes(_:)` covers controllers
/// too — route existence is information the build has before the binary exists.
///
/// `@Inject` and `@ConfigValue` properties work exactly as on `@Component`
/// types; a controller is built per request by its route factory.
///
/// `path` is an optional base path, combined with every mapped method's own
/// path the same way Spring combines a class-level `@RequestMapping` with
/// its method-level mappings: concatenated, collapsing a doubled `/` at the
/// seam, with a mapping of exactly `"/"` resolving to the base path itself
/// (not a trailing-slash variant of it):
///
///     @Controller("/users")
///     struct UserController {
///         @GetRoute("/")          // → GET /users
///         func index(_ context: RequestContext) -> [User] { ... }
///
///         @GetRoute("/:id")       // → GET /users/:id
///         func show(_ context: RequestContext) -> User { ... }
///     }
///
/// Omitted (or `nil`) — the default — means no prefix, exactly as before;
/// every existing `@Controller` type is unaffected.
///
/// `pipelines` names the middleware lanes every route in this controller
/// runs through, in order — `MiddlewareRegistration.lane("name", [...])` declarations.
/// Omitted means the default lane, exactly as before lanes existed. A
/// controller that wants the default stack *plus* extras concatenates:
/// `pipelines: [MiddlewareRegistration.defaultLane, "admin"]`; one that
/// wants almost nothing (static assets, health probes) names a bare lane
/// alone. Referencing an undeclared lane fails when dispatch is built — at
/// bootstrap, naming the route and the lane.
// `arbitrary` because one member per route is introduced, named after the
// handler method — `_flightRoute_show_0`. Those names are not knowable from
// the attribute alone, which is exactly what `arbitrary` is for.
@attached(member, names: named(init), arbitrary)
public macro Controller(
    _ path: String? = nil,
    pipelines: [PipelineLane] = [.default]
) =
    #externalMacro(module: "FlightWebMacrosImpl", type: "ControllerMacro")

/// Marks a type as a middleware layer. Expands like `@Component` — a
/// parameterized initializer over its `@Inject`/`@ConfigValue` properties —
/// and additionally declares the type's conformance to ``Middleware``, so the
/// type only needs to supply `handle(_:next:)`:
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
/// `@Inject` and `@ConfigValue` properties work exactly as on `@Component`
/// types. A middleware is a singleton, built once and shared: the chain is
/// assembled once, at composition, not per request.
///
/// `@Middleware` registers the type as an ordinary component. It does
/// **not** add it to any request pipeline — hand an instance to
/// `MiddlewareRegistration.lane(_:_:)` in a module's `middleware` for that,
/// which is also where its position relative to other middleware is decided.
/// A `@Middleware` type in no lane is a fully-formed, independently
/// constructible and testable component that simply never runs.
@attached(member, names: named(init))
@attached(extension, conformances: Middleware)
public macro Middleware() =
    #externalMacro(module: "FlightWebMacrosImpl", type: "MiddlewareMacro")

// MARK: - Route mappings (§4)
//
// Pure markers, same family as `@Inject`: the generated code lives in
// `@Controller`'s expansion, which reads these attributes off the methods.
// Each validates its attachment site so misuse fails at the method.
//
// Handler shapes accepted (any combination of `async`/`throws`):
//     func f(_ context: RequestContext) -> some ResponseEncodable / Response
//     func f(_ context: RequestContext, body: SomeDecodable) -> …
//     func f(_ context: RequestContext)              // answers 204
//
// The path must be a string literal — the route table is compile-time
// information (§4); a computed path is a build error at the site.
//
// `maxBodyBytes` overrides the transport's global request-body cap for
// this one route — the knob that lets an upload route accept gigabytes
// without arguing for a gigabyte global cap. On a route whose handler
// takes `body: RequestBodyStream` it caps the cumulative stream instead,
// enforced as bytes arrive.
//
// `pipelines` overrides the controller's lanes for this one route, and
// **replaces** rather than appends: the route's list is the whole stack.
// Replacement is what expresses both directions — a public controller with
// one authenticated route, and an authenticated controller with one public
// route — where appending can only ever add. Omitted, the route inherits
// whatever the controller declared.
//
//     @Controller("/dashboard", pipelines: [.authenticated])
//     final class DashboardController {
//         @GetRoute("/", pipelines: [.public])   // deliberate, and says so
//         func index(_ context: RequestContext) -> Response { ... }
//
//         @GetRoute("/admin")                    // inherits [.authenticated]
//         func admin(_ context: RequestContext) -> Response { ... }
//     }
//
// Narrowing away a security lane without naming `.public` is a build
// warning: dropping authentication by accident is the mistake worth
// catching, and `.public` is how you say you meant it.

@attached(peer)
public macro GetRoute(
    _ path: String, maxBodyBytes: Int? = nil, pipelines: [PipelineLane]? = nil
) =
    #externalMacro(module: "FlightWebMacrosImpl", type: "RouteMacro")

@attached(peer)
public macro PostRoute(
    _ path: String, maxBodyBytes: Int? = nil, pipelines: [PipelineLane]? = nil
) =
    #externalMacro(module: "FlightWebMacrosImpl", type: "RouteMacro")

@attached(peer)
public macro PutRoute(
    _ path: String, maxBodyBytes: Int? = nil, pipelines: [PipelineLane]? = nil
) =
    #externalMacro(module: "FlightWebMacrosImpl", type: "RouteMacro")

@attached(peer)
public macro PatchRoute(
    _ path: String, maxBodyBytes: Int? = nil, pipelines: [PipelineLane]? = nil
) =
    #externalMacro(module: "FlightWebMacrosImpl", type: "RouteMacro")

@attached(peer)
public macro DeleteRoute(
    _ path: String, maxBodyBytes: Int? = nil, pipelines: [PipelineLane]? = nil
) =
    #externalMacro(module: "FlightWebMacrosImpl", type: "RouteMacro")

/// A WebSocket upgrade route (§6.1). The method must return a
/// `WebSocketUpgradeHandler` (or `any WebSocketUpgradeHandler`); the build
/// plugin emits a route-table entry exactly like any other, just tagged as
/// an upgrade route. At dispatch time a matched upgrade route produces
/// `Response.upgrade`; the active transport performs the HTTP 101 handshake
/// and hands the frame stream to the handler.
@attached(peer)
public macro WebSocketRoute(_ path: String, pipelines: [PipelineLane]? = nil) =
    #externalMacro(module: "FlightWebMacrosImpl", type: "RouteMacro")
