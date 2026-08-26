# ``FlightWeb``

HTTP routing, middleware, and WebSockets — declared on controller types,
resolved at build time.

## Overview

A route in Flight is a method on a type the container knows how to build, not
a closure captured on an application object:

```swift
@Controller("/orders")
final class OrderController: Sendable {
    @Autowired var orders: OrderService

    @GetMapping("/:id")
    func show(_ request: Request) async throws -> Response {
        guard let id = request.pathParam("id").flatMap(UUID.init) else {
            throw HTTPError(status: .badRequest, detail: "id must be a UUID")
        }
        return try .json(await orders.find(id))
    }
}
```

That difference is the point of the module. A controller is an ordinary
`Sendable` type with injected dependencies, so it can be constructed in a
test and called directly — no server, no port, no request loop. The routing
table is assembled by the same build plugin that wires the container, so a
handler whose dependencies are unregistered is a build error rather than a
404 at 3am.

## Requests and responses

``Request`` is a value: method, path, headers, query, body, and the path
parameters the match produced. It has no reference to a connection, which is
what lets a test construct one.

``Response`` is an enum rather than a builder, so the compiler knows which
cases exist:

```swift
.json(order)                     // encoded, with a content type
.text("ok")
.status(.noContent)
.stream { writer in ... }        // server-sent events
```

Anything conforming to ``ResponseEncodable`` can be returned directly, and
``WebCoders`` decides how a body encodes and decodes.

## Errors are part of the contract

Throwing ``HTTPError`` produces an [RFC 9457][] problem-details body:

```swift
throw HTTPError(status: .notFound, detail: "no order \(id)")
```

A domain error conforming to ``HTTPErrorRepresentable`` maps itself, so a
service layer can throw its own errors and the transport translates them at
the edge instead of every handler catching and re-wrapping.

[RFC 9457]: https://www.rfc-editor.org/rfc/rfc9457

## Middleware

``Middleware`` is a function from a ``Request`` and a ``Next`` to a
``Response``. Registration is declarative and ordered, and the chain is
composed once at startup rather than per request:

```swift
registerMiddleware(order: 10) { request, next in
    let start = ContinuousClock.now
    let response = try await next(request)
    metrics.record(ContinuousClock.now - start)
    return response
}
```

## WebSockets and streaming

``WebSocketMapping(_:)`` upgrades a route; the handler receives a
``WebSocketConnection`` and owns it for the connection's lifetime.
``ServerSentEvent`` and ``ServerSentEventWriter`` cover the one-directional
case, which is usually what a dashboard actually needs.

For channels — named topics, presence, and a browser client — see
`FlightChannels`, which is built on this module rather than beside it.

## The transport is a seam

``ServerTransport`` is the protocol an HTTP server implements;
``FlightWebModule`` is generic over it. The shipped transport is built on
HummingbirdCore, and nothing in this module's API mentions it. That is what
makes a transport swappable and what makes `FlightWebTesting` able to run a
whole application without binding a port.

## Topics

### Controllers and routes

- ``Controller(_:)``
- ``GetMapping(_:)``
- ``PostMapping(_:)``
- ``PutMapping(_:)``
- ``PatchMapping(_:)``
- ``DeleteMapping(_:)``
- ``WebSocketMapping(_:)``

### Requests and responses

- ``Request``
- ``RequestContext``
- ``Response``
- ``ResponseEncodable``
- ``ContentType``
- ``WebCoders``
- ``MediaType``
- ``FormDecoder``

### Static assets

- ``AssetMountOptions``
- ``AssetMountRegistration``

### Resumable uploads

- ``UploadStore``
- ``UploadInfo``
- ``DiskUploadStore``
- ``UploadMountOptions``
- ``ResumableUploadError``

### Request bodies

- ``RequestBodyStream``
- ``BodyStreamLimitError``
- ``MultipartReader``
- ``MultipartPart``
- ``MultipartLimits``
- ``MultipartError``

### Serving sized content

- ``serveContent(for:_:)``
- ``ContentDescriptor``
- ``ByteSource``
- ``FileByteSource``
- ``DataByteSource``
- ``ByteSourceError``
- ``FileResponse``
- ``EntityTag``
- ``ContentHashCache``
- ``HTTPDate``

### Errors

- ``HTTPError``
- ``HTTPErrorRepresentable``
- ``UnsupportedMediaTypeError``
- ``ProblemDetails``
- ``SimpleErrorBody``
- ``BodyDecodingError``
- ``WebCodersError``

### Middleware

- ``Middleware``
- ``Next``
- ``MiddlewareResult``
- ``MiddlewareRegistration``

### Routing internals

- ``Router``
- ``RoutePattern``
- ``RouteMatch``
- ``RouteRegistration``
- ``Dispatch``
- ``DispatchBuilder``
- ``RouterError``
- ``RoutingError``

### Streaming and upgrades

- ``ServerSentEvent``
- ``ServerSentEventWriter``
- ``WebSocketConnection``
- ``UpgradeResponse``
- ``WebSocketUpgrade``
- ``UpgradeKind``
- ``WebSocketUpgradeHandler``
- ``WebSocketFrame``
- ``WebSocketCloseCode``
- ``WebSocketError``

### Hosting

- ``FlightWebModule``
- ``ServerTransport``
- ``ServerTransportConfiguration``
