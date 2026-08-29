# Flight Web

The HTTP request lifecycle layer of Flight — routing, middleware, request and
response representation, WebSocket and Server-Sent Events, and the
`ServerTransport` seam a concrete server plugs in underneath (the
Phoenix/Bandit relationship, not bring-your-own-framework). Implements the
flight-web design doc (as revised: §5.2 wraps a maintained low-level
transport instead of hand-rolling HTTP; §5.6 containment) on top of Flight
Core's `Container`/`FlightModule`/`Scope` — through exactly one channel,
`FlightModule`, like every other Flight package.

## What's here

| Product | Contents |
|---|---|
| `FlightWeb` | `RequestContext`, `Request`/`Response`, middleware lanes, `Router`, `@Controller`/`@GetMapping`/…/`@WebSocketMapping` macros, `ResponseEncodable`, cookies, SSE, streaming bodies, multipart, resumable uploads, static assets, `serveContent`'s conditional/range engine, `WebSocketUpgradeHandler`/`WebSocketConnection`, `ServerTransport` protocol, `FlightWebModule` |
| `FlightTransport` | The default transport (§5.2): wraps **HummingbirdCore** — a mature, versioned low-level HTTP transport — for HTTP/1.1 (keep-alive, pipelining, 100-continue), streaming bodies, and WebSocket protocol handling. The only target in all of Flight that knows what it wraps (§5.6) |
| `FlightWebTesting` | `TestContainer`, `RequestContext.mock`, `TestClient` (in-process dispatch + in-process WebSocket), `InMemoryTransport` (§5.4's socket-free transport) |

## Using it

```swift
import FlightCore
import FlightWeb
import FlightTransport

@Controller
struct UserController {
    @Autowired var userService: UserService          // Flight Core DI, unchanged

    @GetMapping("/users/:id")
    func getUser(_ context: RequestContext) async throws -> UserResponse {
        guard let id = context.pathParam("id") else {
            throw HTTPError(.badRequest, "missing id")
        }
        return try await userService.find(id)        // UserResponse: Codable + ResponseEncodable
    }

    @PostMapping("/users")
    func createUser(_ context: RequestContext, body: CreateUserRequest) async throws -> UserResponse {
        try await userService.create(body)
    }

    @WebSocketMapping("/chat/:roomId")               // §6.1 — same route table
    func chat(_ context: RequestContext) throws -> any WebSocketUpgradeHandler {
        ChatRoomHandler(roomId: context.pathParam("roomId")!)
    }

    @GetMapping("/events")                           // §6.2 — SSE is a response shape
    func events(_ context: RequestContext) -> Response {
        .serverSentEvents { events in
            // `send` suspends until the event has gone out, and answers
            // false once the client is gone — the producer is paced by the
            // reader rather than buffered ahead of it.
            await events.send(data: "hello", event: "greeting")
        }
    }
}

@Middleware
struct Authentication: Middleware {
    func handle(_ context: RequestContext, next: Next) async throws -> Response {
        guard context.request.headers[.authorization] != nil else {
            return .problem(status: .unauthorized, message: "Unauthorized")
        }
        return try await next(context)
    }
}

struct AppModule: FlightModule {
    func configure(_ container: Container) throws {
        try flightRegisterAll(container)             // plugin-generated: components AND controllers
        container.pipeline {                          // the default lane, in order
            RequestLogging.self
            Authentication.self
        }
    }
}

@main struct Main {
    static func main() async throws {
        try await bootstrap(
            configuration: try Configuration.load(),
            modules: [FlightWebModule<FlightTransport>.self, AppModule.self]
        )
    }
}
```

Transport settings come from the same `flight.yaml` everything else uses:
`server.host` (127.0.0.1), `server.port` (8080), `server.backlog`,
`server.max-request-body-bytes`, `server.max-websocket-frame-bytes`.

### Middleware lanes

A *lane* is the whole stack for the routes that name it. `container.pipeline
{ }` declares the default lane; the named form declares another, and a route,
controller or asset mount opts in with `pipelines:`:

```swift
container.pipeline("assets") { RequestLogging.self }
container.pipeline("admin") { RequireAdmin.self }
```

```swift
@Controller("/admin", pipelines: [MiddlewareRegistration.defaultLane, "admin"])
struct AdminController { … }
```

Naming a lane alone means *only* that lane runs, which is how a static-asset
route avoids paying for transaction binding and authentication it can never
use. Concatenate with `defaultLane` to get the usual behaviour plus extras.
An empty block still declares its lane. Referencing a lane nobody declared
fails when dispatch is built — at bootstrap, naming the route and the lane,
never as a 500.

Middleware types are composed once, when the dispatch closure is assembled,
so a request pays one call per layer and never the construction of the chain.
The older `registerMiddleware(_:order:)` / `.respond` / `.continue` API is
deprecated: return early from `handle` instead of returning a result enum.

### Bodies

Request bodies are buffered by default, bounded by
`server.max-request-body-bytes`. A handler that takes `body:
RequestBodyStream` is recorded as streaming-bodied in the route table, and
the transport — which asks the table before collecting bytes, exactly as it
already asks `acceptsUpgrade` — pulls chunks through with real backpressure
instead:

```swift
@PostMapping("/import", maxBodyBytes: 2 << 30)
func importArchive(_ context: RequestContext, body: RequestBodyStream) async throws -> Response {
    for try await chunk in body.chunks { try await ingest(chunk) }
    return .noContent
}
```

`MultipartReader` parses `multipart/form-data` pull-based and in constant
memory, with Go's post-CVE-2023-24536 part and header caps; filenames are
hardened down to the `.`/`..` basename edge.

Responses stream the same way. `Response.streaming` hands the producer a
`ResponseBodyWriter` whose `write` suspends until the transport has taken the
chunk, and reports a disconnected client at the next write — so a producer
faster than its reader is slowed by it rather than buffered ahead of it.

### Cookies

```swift
response.settingCookie(Cookie(name: "session", value: token))   // HttpOnly + SameSite=Lax by default
request.cookie("session")
Response.seeOther("/dashboard")                                  // the 303 a form-post login wants
Cookie.expiring("session")                                       // deletion
```

`settingCookie` appends rather than replaces, because several cookies means
several headers.

### Files, assets and uploads

`serveContent` is a pure function over a `ByteSource` implementing RFC 9110's
conditional and range rules — `If-None-Match`, `If-Modified-Since`,
`If-Range`, suffix ranges, EOF clamping, 416. `FileByteSource` opens once and
`fstat`s the descriptor, which closes the stat-vs-open TOCTOU at the type
level, and reads with `pread` off the cooperative pool.

`container.assets(at:root:pipelines:)` mounts a directory: content hashing,
`Accept-Encoding` negotiation against precompressed siblings, per-pattern
cache headers, an SPA fallback, and path containment that resolves before it
compares.

`ResumableUploads` implements tus 1.0 over a `DiskUploadStore` whose recorded
offsets can only be produced by a proof type that performs the `fsync` — the
ordering is unwritable-wrong rather than merely tested.

### Wire format

Response encoding, request decoding, and error bodies are configurable —
`ResponseEncodable` is unusable for most real APIs otherwise:

```yaml
web:
  json:
    key-strategy: snake-case     # snake-case | as-is (default)
    date-strategy: iso8601       # iso8601 (default) | seconds | milliseconds | foundation
    pretty-print: false
  errors:
    format: problem              # problem (default, RFC 9457) | simple
```

Dates default to ISO-8601 rather than Foundation's seconds-since-2001
`Double`, which is nearly always wrong on a wire shared with anything that is
not another Foundation client — and silently so, since the field is present
and numeric, just meaningless to the reader.

Errors default to RFC 9457 `application/problem+json`:

```json
{"status": 404, "title": "Not Found", "detail": "no such user"}
```

`format: simple` keeps the older `{"status", "error"}` shape for clients that
already parse it. For anything else, register your own `WebCoders` — its
`renderError` is a closure, so an error body need not be JSON at all:

```swift
container.register(WebCoders.self, scope: .singleton) { _ in
    var coders = WebCoders.default
    coders.jsonEncoder.keyEncodingStrategy = .convertToSnakeCase
    return coders
}
```

An application that registers its own keeps it; Flight only fills in the gap.
A misspelled `web.*` value fails at startup naming the key, not on the first
request that happens to encode something.

### HTTPS

TLS is off until a certificate and key are named, and on as soon as they are —
there is no separate enable flag to forget:

```yaml
server:
  tls:
    certificate-chain-path: /etc/tls/fullchain.pem
    private-key-path: /etc/tls/privkey.pem
```

Both are PEM; the chain is leaf first, intermediates after. Serving only the
leaf is the usual cause of "works in curl, fails in a browser". Naming one
key without the other fails at startup rather than falling back to
plaintext — a server that was meant to be HTTPS and quietly is not is the
worst of the three outcomes.

Mutual TLS, when clients must present a certificate too:

```yaml
server:
  tls:
    certificate-chain-path: /etc/tls/fullchain.pem
    private-key-path: /etc/tls/privkey.pem
    trust-roots-path: /etc/tls/ca.pem
    client-authentication: require   # none | request | require
```

`request` asks for a certificate, verifies it if one is offered, and serves
clients that decline. `require` rejects the handshake without a trusted one.
Either mode needs `trust-roots-path`; demanding client certificates with
nothing to verify them against is a startup error.

Terminating TLS at nginx or a load balancer instead is equally supported —
leave these keys out and Flight serves plaintext to the proxy. WebSocket
upgrades ride whatever the listener is doing, so `wss://` needs no separate
configuration.

Controllers must be `Sendable` — one instance serves concurrent requests.
An internal struct whose `@Autowired`/`@ConfigValue` dependencies are
Sendable gets the conformance implicitly; `public` controllers declare it
(`public struct UserController: Sendable`). A non-Sendable controller is a
compile error at the generated registration, not a runtime race.

Testing (§7) needs no socket:

```swift
let container = try TestContainer.build { AppModule() }
let client = try TestClient(container: container)
#expect(await client.get("/users/999").status == .notFound)

let socket = try await client.webSocket("/chat/lobby")   // in-process upgrade
```

## How routing rides the one registration pipeline (§4)

`@Controller` expands exactly like `@Component` — resolving `init(_flight:)`,
`_flightRegister(_:)` thunk, `_FlightRegistrable` conformance — plus one
**`RouteRegistration` component per mapped method**, registered through the same
`Container.register` call every component goes through. The route table is not a
parallel mechanism: `FlightWebModule`'s service collects the route components
post-freeze, validates them (conflicts and malformed patterns fail startup,
naming both declaration sites), and builds the dispatch closure handed to the
active transport. Routes are therefore visible to Core introspection
(`allRegistrations()`) like any other component — an Actuator gets a route
dashboard for free.

The build plugin side is Flight Core's existing `FlightRegistrationPlugin`,
generalized by one word: its scanner now recognizes `@Controller` alongside
`@Component` (a name-level change — Core references no Flight Web types), so
the generated `flightRegisterAll(_:)` covers controllers, and route
existence + path-pattern validity are compile-time information (`@GetMapping`
rejects non-literal and malformed paths at the declaration site).

### Base paths (`@Controller("/users")`)

`@Controller` takes an optional base path, combined with every mapped
method's own path the same way Spring combines a class-level
`@RequestMapping` with its method-level mappings — concatenated, collapsing
a doubled `/` at the seam, with a bare `@GetMapping("/")` resolving to the
base path itself rather than a trailing-slash variant of it:

```swift
@Controller("/users")
struct UserController {
    @GetMapping("/")          // → GET /users
    func index(_ context: RequestContext) -> [User] { ... }

    @GetMapping("/:id")       // → GET /users/:id
    func show(_ context: RequestContext) -> User { ... }
}
```

The combination happens once, at macro-expansion time — the generated
`RouteRegistration` carries the already-joined literal, so there's no
runtime string concatenation and no cost over writing the full path by hand.
Duplicate-route detection runs on the combined path, so two methods that
only collide once the base folds in are still caught as a compile error, and
the diagnostic names the full route. Omitted (or `nil`) — the default — is
unprefixed, exactly as before; every controller written before this existed
is unaffected.

## Design deltas from the doc

Recorded here the way Core records its spec deviations in SPIKE-FINDINGS:

1. **`Response.upgrade` carries an `UpgradeResponse`, not a bare handler.**
   The doc's `case upgrade(handler: any ConnectionUpgradeHandler)` gives the
   transport no way to supply the `RequestContext` the handler's own
   signature requires (and a context payload would make `Response` and
   `RequestContext` mutually recursive). `UpgradeResponse` pairs the handler
   with a router-built `run` closure that has the context captured; the
   transport still sees neither routing nor contexts.
2. **Scope-per-request is created directly, not via `Container.withScope`.**
   `withScope`'s lifetime is its body, but streaming bodies and upgraded
   connections legitimately outlive the dispatch call. The per-request
   `Scope` ends when the request's last reference (context, stream, or
   connection handler) is released — same cleanup, no closed-scope trap
   mid-SSE.
3. **`RequestContext` gains `resolve(_:qualifier:)`** (backed by a private
   container reference). A `Scope` is only usable through
   `Container.resolve(_:in:)`; without this the doc's `scope` field would be
   inert for handlers. Purely additive — the doc's fields are unchanged.
4. **`runMiddleware` returning early on `.respond`** means the terminal
   routing middleware *returns* the matched handler's response (and also
   records it in `context.response`); a chain that completes without
   answering yields `context.response`, which starts as 404.
5. **HTTP/2 is deferred.** v1 of `FlightTransport` builds HummingbirdCore's
   HTTP/1.1 channel (keep-alive/pipelining); h2 needs a TLS configuration
   surface Flight doesn't define yet. Nothing in the `ServerTransport`
   contract is version-shaped — h2 lands inside the transport without
   touching the seam.
6. **Middleware registration mechanism.** The doc specifies the chain (§3)
   but not how apps contribute to it. `container.pipeline { }` declares a
   lane of `Middleware` types, composed once and ordered by registration
   sequence — which already reflects both module order and the order within
   a block. `registerMiddleware(_:order:_:)` was the first spelling and is
   deprecated.
7. **WebSocket ping/pong frames are transport-internal on the default
   transport.** HummingbirdCore auto-answers pings and does not surface
   them, so `WebSocketFrame.ping`/`.pong` are never *delivered* through
   `WebSocketConnection.frames` there (sending them works). A synthesized
   `.close` frame precedes the stream finishing, so handlers behave
   identically on the in-memory transport and the wire.
8. **A refused WebSocket handshake answers 400 + connection close on the
   default transport.** Routing and middleware still decide the refusal
   (dispatch runs before the upgrade decision, §6.1), but HummingbirdCore
   writes its own fixed refusal response — the routed status (404, 401, …)
   is not writable through that seam. In-process (`TestClient.webSocket`)
   surfaces the routed status; plain HTTP requests to the same path get the
   routed response on the wire as normal.

## Layout

```
Sources/Web/FlightWeb/             runtime: context, middleware, router, response
                               encoding, SSE, upgrade hook, transport seam,
                               FlightWebModule, macro declarations
Sources/Web/FlightWebMacrosImpl/   compiler plugin: Controller + mapping markers
Sources/Web/FlightTransport/       the default transport wrapping HummingbirdCore (§5.2, §5.6)
Sources/Web/FlightWebTesting/      §7 test-support surface
Tests/Web/FlightWebTests/          runtime suites (swift-testing)
Tests/Web/FlightWebMacroTests/     §4 macro fixtures (XCTest, normative expansions)
Tests/Web/FlightTransportTests/    real-socket HTTP/SSE/WebSocket integration
```

## Known gaps

No connection idle or read timeout: a half-open connection is held until the
OS gives up, roughly four minutes. Recorded in [GAPS.md](../GAPS.md).

## Deliberately not here (§10)

No HTTP/2 or HTTP/3 (HummingbirdCore supports HTTP/2 and the builder seam
would take it; nothing here has needed it yet), no templating/SSR (a future
consumer of the upgrade hook), no persistence
(Flight Data), no runtime route-registration API (routes are the macro path;
`registerRoute` exists as the bootstrap-time escape hatch beside it, exactly
as `container.register` sits beside `@Component`), and **no hand-rolled HTTP
parsing** — `FlightTransport` wraps HummingbirdCore rather than reimplementing
HTTP/1.1 correctness, request-smuggling mitigations, and WebSocket protocol
handling; Flight owns routing and dispatch, not byte-level protocol work.
Vapor remains out of scope as a category mismatch (§5.1) — a full framework,
not a transport.
