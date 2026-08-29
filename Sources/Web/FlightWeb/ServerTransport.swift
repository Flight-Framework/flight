import FlightCore
import ServiceLifecycle

/// How a transport reads its settings out of the app-wide Flight
/// configuration (host, port, limits — whatever that transport needs).
/// Letting the *type* do this keeps `FlightWebModule` generic over
/// transports without knowing any transport's option set.
public protocol ServerTransportConfiguration: Sendable {
    init(configuration: FlightCore.Configuration) throws
}

/// The server boundary (§5): the thing that owns a socket, parses raw bytes
/// into an HTTP request, and hands back a response. Routing, middleware, and
/// dispatch are **not** behind this seam — they are Flight Web's own, as
/// fixed as Phoenix's router; only the transport underneath is pluggable
/// (the Phoenix/Bandit relationship, §5.1).
///
/// Hard requirements on every conforming transport, default or third-party.
/// This list is the whole contract: a transport built against it and nothing
/// else must work, so anything Flight Web assumes belongs here. Three of
/// these were assumptions before they were requirements, and a transport
/// written to the older list compiled cleanly and broke HEAD and every
/// streaming route.
///
/// - Support all three `Response` kinds. A transport that buffers
///   `.streaming` bodies silently breaks SSE and long downloads (§6.2);
///   one that can't perform `.upgrade`'s protocol switch breaks WebSocket.
/// - Present `dispatch` as structured `async` — no `EventLoopFuture` at this
///   boundary, whatever event-loop machinery lives inside (§5.5).
/// - Suspend in `run()` until shutdown, matching ServiceLifecycle's
///   `Service` contract exactly (§5.3, Flight Core §7).
/// - **Suppress the response body for a `HEAD` request.** The router answers
///   `HEAD` by falling back to the `GET` route and returning that route's
///   full response; removing the body is the transport's job, and no layer
///   above it does so.
/// - **Honour `Dispatch.bodyMode`.** Ask it before reading any of the
///   request body, and for a `.streaming` route deliver the body as a
///   `RequestBodyStream` on the `Request` rather than collecting it. A
///   transport that ignores this is a wiring defect the runtime surfaces as
///   a 500 on every streaming route — it cannot be recovered from above.
/// - **Enforce the body cap and answer 413.** `bodyMode` carries the route's
///   own cap when it has one; the transport's configured maximum applies
///   otherwise. Enforce it as bytes arrive, never by buffering first, and
///   answer `413` without dispatching.
public protocol ServerTransport: Service, Sendable {
    associatedtype Configuration: ServerTransportConfiguration

    /// Bind and begin accepting connections (on `run()`). Every parsed
    /// request is handed to `dispatch`. The transport has zero opinion about
    /// routing, middleware, or dispatch order — it never sees a route table,
    /// never sees `RequestContext`, never sees `Container`.
    init(configuration: Configuration, dispatch: Dispatch)
}
