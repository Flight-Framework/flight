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
from a container — the same `DispatchBuilder` the server uses, route
validation included — and answers requests in-process:

```swift
let container = try TestContainer.build {
    AppModule()
} overriding: { container in
    container.override(OrderService.self, scope: .singleton) { _ in StubOrderService() }
}
let client = try TestClient(container: container)
let response = try await client.get("/orders/\(id)")
#expect(response.status == .ok)
```

**The whole application, without a socket.** ``InMemoryTransport`` conforms
to `ServerTransport`, so `FlightWebModule` boots against it and every layer
runs — bootstrap, module ordering, middleware, dispatch — with requests
delivered through memory instead of TCP.

## Overriding is the point of the container

``TestContainer/build(configuration:_:overriding:)`` runs the real modules
and then applies overrides on top. `Container.override` wins over any later
`register` for the same key, so a module can register its real component and
the test still gets the stub — no conditional wiring inside production code,
no `#if DEBUG`.

``Components`` registers loose values by name for tests that need one or two
things rather than a module.

## WebSockets

``InMemoryWebSocket`` is the socket side of the same idea, and
``InMemoryTransportHub`` connects a test's client end to the application's
server end. Channel joins, broadcasts and disconnects are all exercisable
without a browser or a port.

## Topics

### Testing routes

- ``TestClient``
- ``TestContainer``
- ``Components``

### Testing the whole application

- ``InMemoryTransport``
- ``InMemoryTransportHub``

### WebSockets

- ``InMemoryWebSocket``
