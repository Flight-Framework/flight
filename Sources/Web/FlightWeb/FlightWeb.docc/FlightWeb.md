# ``FlightWeb``

HTTP routing, middleware, and WebSockets — declared on controller types,
resolved at build time.

## Overview

A route in Flight is a method on a type the composition root knows how to build, not
a closure captured on an application object:

```swift
@Controller("/orders")
final class OrderController: Sendable {
    @Inject var orders: OrderService

    @GetRoute("/:id")
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
table is assembled by the same build plugin that generates the composition root, so a
handler whose dependencies aren't provided is a build error rather than a
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

``Middleware`` is a type with one method, from a ``RequestContext`` and a
``Next`` to a ``Response``. `@Middleware` makes it a component like any
other, so it can inject its dependencies:

```swift
@Middleware
struct RequestTiming: Middleware {
    @Inject var metrics: MetricsRecorder

    func handle(_ context: RequestContext, next: Next) async throws -> Response {
        let start = ContinuousClock.now
        let response = try await next(context)
        metrics.record(ContinuousClock.now - start)
        return response
    }
}
```

Order is declared in one place, outermost first, and the chain is composed
once at startup rather than per request:

```swift
MiddlewareRegistration.lane(.default, [RequestTiming(), Authentication()])
```

A ``PipelineLane`` names an alternative stack that routes opt into with
`pipelines:` on a controller or a route — how a static-asset route avoids
paying for authentication it can never use. Naming a lane alone runs *only*
that lane; `[.default, "admin"]` concatenates.

The older `registerMiddleware(_:order:)` closure API and its result-enum
return type are gone with the container; conform a type to ``Middleware`` and
hand it to `MiddlewareRegistration.lane(_:_:)`, returning early from `handle`
rather than a result enum.

## WebSockets and streaming

``WebSocketRoute(_:pipelines:)`` upgrades a route; the handler receives a
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

- ``Controller(_:pipelines:)``
- ``GetRoute(_:maxBodyBytes:pipelines:)``
- ``PostRoute(_:maxBodyBytes:pipelines:)``
- ``PutRoute(_:maxBodyBytes:pipelines:)``
- ``PatchRoute(_:maxBodyBytes:pipelines:)``
- ``DeleteRoute(_:maxBodyBytes:pipelines:)``
- ``WebSocketRoute(_:pipelines:)``

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

### Cookies

- ``Cookie``

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
- ``ErrorMapper``

### Middleware

- ``Middleware``
- ``Next``
- ``PipelineLane``
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
