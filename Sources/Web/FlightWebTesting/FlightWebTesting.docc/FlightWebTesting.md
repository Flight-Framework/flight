# ``FlightWebTesting``

Testing a Flight application at three sizes, none of which need a port.

## Overview

The reason a controller is a type with injected dependencies rather than a
closure on an application object is that it can be tested three different
ways, and you pick the smallest one that answers the question.

**A controller on its own.** No container, no routing, no server — construct
it and call the method:

```swift
@Test func rejectsAMalformedID() async throws {
    let controller = OrderController(orders: StubOrderService())
    await #expect(throws: HTTPError.self) {
        try await controller.show(Request(method: .get, path: "/orders/nope"))
    }
}
```

**Routing and middleware.** ``TestClient`` builds the real dispatch table
from the routes and middleware you hand it — the same `DispatchBuilder` the
server uses, route validation included — and answers requests in-process. A
route factory constructs the controller per request, so a stubbed dependency
is just a value passed in:

```swift
let client = try TestClient(routes: [
    OrderController._flightRoute_show_0 { _ in OrderController(orders: StubOrderService()) }
])
let response = try await client.get("/orders/\(id)")
#expect(response.status == .ok)
```

**The whole application, without a socket.** ``InMemoryTransport`` conforms
to `ServerTransport`, so `FlightWebModule` boots against it and every layer
runs — bootstrap, module ordering, middleware, dispatch — with requests
delivered through memory instead of TCP.

## Stubbing a dependency

There is no container to override: you construct the component under test (or
its route, through the macro-generated factory) with the fake passed to its
initializer. A component takes what it needs as `@Inject` parameters, so
`OrderController(orders: StubOrderService())` is the whole of it — no
conditional wiring inside production code, no `#if DEBUG`.

## WebSockets

``InMemoryWebSocket`` is the socket side of the same idea, and
``InMemoryTransportHub`` connects a test's client end to the application's
server end. Channel joins, broadcasts and disconnects are all exercisable
without a browser or a port.

## Topics

### Testing routes

- ``TestClient``

### Testing the whole application

- ``InMemoryTransport``
- ``InMemoryTransportHub``

### WebSockets

- ``InMemoryWebSocket``
