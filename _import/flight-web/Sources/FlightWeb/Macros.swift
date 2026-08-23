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
@attached(member, names: named(init), named(_flightRegister))
@attached(extension, conformances: _FlightRegistrable)
public macro Controller(_ path: String? = nil) =
    #externalMacro(module: "FlightWebMacrosImpl", type: "ControllerMacro")

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

/// A connection-upgrade route (§6.1). The method must return a
/// `ConnectionUpgradeHandler` (or `any ConnectionUpgradeHandler`); the build
/// plugin emits a route-table entry exactly like any other, just tagged as
/// an upgrade route. At dispatch time a matched upgrade route produces
/// `Response.upgrade`; the active transport performs the HTTP 101 handshake
/// and hands the frame stream to the handler.
@attached(peer)
public macro WebSocketMapping(_ path: String) =
    #externalMacro(module: "FlightWebMacrosImpl", type: "RouteMappingMacro")
