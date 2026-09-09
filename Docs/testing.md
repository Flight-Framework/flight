# Testing a Flight application

The reason for the dependency injection is this page. A Flight application is
meant to be testable without a socket, a database, or a clock — you run the
real controllers, the real routing and the real middleware, and replace only
the parts that would reach outside the process.

There are three sizes of test. Most suites want the middle one.

| | What runs | Reach for it when |
|---|---|---|
| [Call the handler](#calling-a-handler-directly) | one method | the logic is the point and routing is not |
| [`Components`](#components--the-usual-choice) | the real controller, routing, middleware, DI | most of the time |
| [`AppModule` + `override`](#the-whole-application) | every module the application boots | you are testing the wiring itself |

## Routes under test — the usual choice

Build exactly the routes under test, giving each controller the fakes it
needs. Nothing else is wired, so the suite is not coupled to code it does not
exercise. A `@Controller`'s route factory constructs the controller per
request, so a fake is just a value passed in:

```swift
let repo = InMemoryUsers(users: [ada])
let client = try TestClient(routes: [
    UserController._flightRoute_show_0 { _ in
        UserController(users: UserService(repository: repo))
    }
])

let response = await client.get("/users/\(ada.id)")
#expect(response.status == .ok)
```

`TestClient` dispatches **in process**. Routing, middleware, dependency
injection, request decoding and JSON encoding all run for real; there is no
socket and no port to collide with. These tests are fast because the network
is absent, not because the framework is stubbed.

A fake is a type that conforms. There is no mock framework and nothing
generated:

```swift
final class InMemoryUsers: UserRepositoryProtocol, Sendable {
    private let users = Mutex<[User]>([])
    var stored: [User] { users.withLock { $0 } }
    // …
}
```

Because it is a real object, a test can interrogate it afterwards — which is
how you assert on **effects** rather than only on what came back:

```swift
#expect(response.status == .badRequest)
#expect(users.stored.isEmpty, "validation must run before the write")
```

## Calling a handler directly

A `@Controller` is an ordinary struct. When routing is not what you are
testing, construct it and call the method:

```swift
let controller = UserController(users: InMemoryUsers(users: users))
let result = try await controller.list(.mock())
```

`RequestContext.mock` builds a context with whatever the handler needs —
path parameters, headers, a body.

> `@Controller` generates a memberwise initializer over the type's injected
> properties — `UserController(users:)` — which is what you call here and what
> the route factory calls per request.

## The whole application

Composing the real modules is the only way to test the **wiring** — and it
catches a class of bug the other two cannot, because building the graph is
where composition mistakes surface: an initializer that throws on real
configuration, or two modules providing the same type ambiguously, is
invisible to a test that never composes.

There is no "compose everything but swap one" — and none is needed. A
full-composition test composes the real modules:

```swift
let app = try Flight.assemble(configuration: config, modules: [appModule])
```

and a test that needs a fake builds the component under test directly (above),
with the fake passed to its initializer. The two are separate on purpose: one
proves the wiring, the other exercises behavior.

The demo carries a `BootstrapTests` suite that does nothing but compose its
real modules, for exactly this reason.

## Testing the layers

Each layer ships its own test support, and none of them need a server.

### HTTP — `FlightWebTesting`

`TestClient` for in-process requests, `RequestContext.mock` for direct handler
calls, and `InMemoryTransport` when you want the transport seam without a
socket.

### PubSub — `FlightPubSubTesting`

`InMemoryCluster` stands in for the wire between nodes, so fan-out across a
cluster can be tested in a unit suite. Each call to `makeAdapter()` is another
node on it:

```swift
let cluster = InMemoryCluster()
let nodeA = cluster.makeAdapter()
let nodeB = cluster.makeAdapter()
```

`RecordingAdapter` is the simpler tool when you only need to see what was
published — its `broadcasts` property is every `Message` that went out.

### Channels — `FlightChannelsTesting`

`InMemoryChannelTransport` connects a real `ChannelClient` to a real server
in-process — the whole join/push/reply protocol with no WebSocket.
`ChannelWireClient` drives raw envelopes when you are testing the protocol
itself rather than an application on top of it.

```swift
let client = ChannelClient(
    url: URL(string: "flight-test:///socket")!,
    transport: InMemoryChannelTransport(testClient: testClient, query: "token=…"))
```

### Presence — `FlightPresenceClient`

`ChannelPresence` maintains the presence list from `flight:presence_state` and
`flight:presence_diff` messages, so a test asserts on the list rather than on
the wire.

### Data — `FlightDataTesting`

`InMemoryDataSource` and `InMemoryDataModule` stand in for a database.
`DataSourceConformance` is a contract suite every data source must satisfy —
run it against your own adapter and it will tell you where the behaviour
diverges.

### Cache — `FlightCacheTesting`

`RecordingCache` is a working in-memory cache that also records what was
asked of it, so a test can assert something *was cached* — or evicted —
rather than only that it returned the right value.

## What still needs a real server

Nothing in this page does. Where a suite genuinely needs Postgres or Valkey —
testing a driver rather than an application — the packages that own those
drivers carry a `scripts/test.sh` that starts throwaway servers, runs the
suite and cleans up.

An application built on Flight should not need one: depend on a protocol,
pass a fake, and let the driver's own package prove the driver works.
