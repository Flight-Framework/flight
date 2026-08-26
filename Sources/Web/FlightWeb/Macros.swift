import FlightCore

/// Marks a type as a routing controller (§4). Expands exactly like
/// `@Component` (Flight Core §5.1) — resolving `init(_flight:)`, a
/// `_flightRegister(_:)` thunk, `_FlightRegistrable` conformance — plus one
/// `RouteRegistration` component per `@GetMapping`/`@PostMapping`/… method. One
/// registration pipeline in all of Flight; routes are just one kind of thing
/// it registers (§4).
///
/// The build plugin (Flight Core's `FlightRegistrationPlugin`) picks
/// `@Controller` types up in the same source-scanning pass as `@Component`,
/// so the generated `flightRegisterAll(_:)` covers controllers too — route
/// existence is information the build has before the binary exists.
///
/// `@Autowired` and `@ConfigValue` properties work exactly as on
/// `@Component` types. Controllers are singleton components.
///
/// `path` is an optional base path, combined with every mapped method's own
/// path the same way Spring combines a class-level `@RequestMapping` with
/// its method-level mappings: concatenated, collapsing a doubled `/` at the
/// seam, with a mapping of exactly `"/"` resolving to the base path itself
/// (not a trailing-slash variant of it):
///
///     @Controller("/users")
///     struct UserController {
///         @GetMapping("/")          // → GET /users
///         func index(_ context: RequestContext) -> [User] { ... }
///
///         @GetMapping("/:id")       // → GET /users/:id
///         func show(_ context: RequestContext) -> User { ... }
///     }
///
/// Omitted (or `nil`) — the default — means no prefix, exactly as before;
/// every existing `@Controller` type is unaffected.
///
/// `pipelines` names the middleware lanes every route in this controller
/// runs through, in order — `container.pipeline("name") { }` declarations.
/// Omitted means the default lane, exactly as before lanes existed. A
/// controller that wants the default stack *plus* extras concatenates:
/// `pipelines: [MiddlewareRegistration.defaultLane, "admin"]`; one that
/// wants almost nothing (static assets, health probes) names a bare lane
/// alone. Referencing an undeclared lane fails when dispatch is built — at
/// bootstrap, naming the route and the lane.
@attached(member, names: named(init), named(_flightRegister))
@attached(extension, conformances: _FlightRegistrable)
public macro Controller(
    _ path: String? = nil,
    pipelines: [String] = [MiddlewareRegistration.defaultLane]
) =
    #externalMacro(module: "FlightWebMacrosImpl", type: "ControllerMacro")

/// Marks a type as a middleware layer. Expands like `@Component` — resolving
/// `init(_flight:)`, a `_flightRegister(_:)` thunk, `_FlightRegistrable`
/// conformance — and additionally declares the type's conformance to
/// ``Middleware``, so the type only needs to supply `handle(_:next:)`:
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
/// `@Autowired` and `@ConfigValue` properties work exactly as on `@Component`
/// types. Always `.singleton` — there is no `scope:` argument — because a
/// `container.pipeline { }` resolves each type exactly once, when the chain
/// is first assembled; a `.scoped` instance resolved there would be
/// permanently pinned to whichever request happened to trigger that.
///
/// `@Middleware` registers the type as an ordinary component. It does
/// **not** add it to any request pipeline — list it in
/// `container.pipeline { }` for that, which is also where its position
/// relative to other middleware is decided. A `@Middleware` type in no
/// `pipeline { }` block is a fully-formed, independently resolvable and
/// testable component that simply never runs.
@attached(member, names: named(init), named(_flightRegister))
@attached(extension, conformances: _FlightRegistrable, Middleware)
public macro Middleware() =
    #externalMacro(module: "FlightWebMacrosImpl", type: "MiddlewareMacro")

// MARK: - Route mappings (§4)
//
// Pure markers, same family as `@Autowired`: the generated code lives in
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

@attached(peer)
public macro GetMapping(_ path: String) =
    #externalMacro(module: "FlightWebMacrosImpl", type: "RouteMappingMacro")

@attached(peer)
public macro PostMapping(_ path: String) =
    #externalMacro(module: "FlightWebMacrosImpl", type: "RouteMappingMacro")

@attached(peer)
public macro PutMapping(_ path: String) =
    #externalMacro(module: "FlightWebMacrosImpl", type: "RouteMappingMacro")

@attached(peer)
public macro PatchMapping(_ path: String) =
    #externalMacro(module: "FlightWebMacrosImpl", type: "RouteMappingMacro")

@attached(peer)
public macro DeleteMapping(_ path: String) =
    #externalMacro(module: "FlightWebMacrosImpl", type: "RouteMappingMacro")

/// A WebSocket upgrade route (§6.1). The method must return a
/// `WebSocketUpgradeHandler` (or `any WebSocketUpgradeHandler`); the build
/// plugin emits a route-table entry exactly like any other, just tagged as
/// an upgrade route. At dispatch time a matched upgrade route produces
/// `Response.upgrade`; the active transport performs the HTTP 101 handshake
/// and hands the frame stream to the handler.
@attached(peer)
public macro WebSocketMapping(_ path: String) =
    #externalMacro(module: "FlightWebMacrosImpl", type: "RouteMappingMacro")
