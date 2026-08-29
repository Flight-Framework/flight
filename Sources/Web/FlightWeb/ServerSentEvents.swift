import Foundation

/// One Server-Sent Event, encoded per the WHATWG EventSource format. SSE is
/// just a response shape, not a routing concern (§6.2) — an SSE endpoint is
/// an ordinary `@GetMapping` handler returning
/// `Response.serverSentEvents { … }` (or `.streaming(contentType:
/// .eventStream)` with hand-formatted chunks).
public struct ServerSentEvent: Sendable, Equatable {
    public var event: String?
    public var data: String
    public var id: String?
    public var retry: Duration?

    public init(
        data: String,
        event: String? = nil,
        id: String? = nil,
        retry: Duration? = nil
    ) {
        self.data = data
        self.event = event
        self.id = id
        self.retry = retry
    }

    /// Wire form: multi-line data becomes one `data:` field per line, so a
    /// payload containing "\n" survives the trip intact.
    public var encoded: Data {
        var out = ""
        if let event { out += "event: \(sanitized(event))\n" }
        if let id { out += "id: \(sanitized(id))\n" }
        if let retry {
            out += "retry: \(retry.components.seconds * 1000 + retry.components.attoseconds / 1_000_000_000_000_000)\n"
        }
        for line in data.split(separator: "\n", omittingEmptySubsequences: false) {
            out += "data: \(line)\n"
        }
        out += "\n"
        return Data(out.utf8)
    }

    /// Field values must not contain newlines — they would terminate the
    /// field early and let a value forge extra fields.
    private func sanitized(_ value: String) -> String {
        value.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }
}

extension Response {
    /// An SSE endpoint's whole response: correct content type, no-cache
    /// headers, and a typed emit surface. The connection stays open until
    /// `produce` returns or the client disconnects (which cancels `produce`).
    public static func serverSentEvents(
        _ produce: @escaping @Sendable (ServerSentEventWriter) async -> Void
    ) -> Response {
        var headers: HTTPFields = [:]
        headers[.cacheControl] = "no-cache"
        return .streaming(contentType: .eventStream, headers: headers) { writer in
            await produce(ServerSentEventWriter(writer: writer))
        }
    }
}

/// The emit surface handed to an SSE producer.
public struct ServerSentEventWriter: Sendable {
    let writer: ResponseBodyWriter

    /// Sends one event, suspending until it has gone out.
    ///
    /// Returns false once the client has disconnected — which it now does at
    /// the first send after the disconnect, rather than after termination had
    /// propagated through a buffer that kept accepting events in the
    /// meantime. Awaiting is the point: an SSE producer looping over updates
    /// is exactly the shape that used to fill memory faster than a slow
    /// client drained it.
    @discardableResult
    public func send(_ event: ServerSentEvent) async -> Bool {
        await writer.write(event.encoded)
    }

    @discardableResult
    public func send(data: String, event: String? = nil, id: String? = nil) async -> Bool {
        await send(ServerSentEvent(data: data, event: event, id: id))
    }

    /// A comment line (":keep-alive") — the standard SSE heartbeat.
    @discardableResult
    public func sendHeartbeat() async -> Bool {
        await writer.write(Data(": keep-alive\n\n".utf8))
    }

    /// Ends the stream early (returning from `produce` also ends it).
    public func finish() {
        writer.finish()
    }
}
