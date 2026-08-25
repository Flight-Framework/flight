import HTTPTypes

/// Re-exported so `import FlightWeb` brings the HTTP vocabulary —
/// `HTTPRequest.Method`, `HTTPFields`, `HTTPField.Name`, `Status` — without
/// a second import, the same way FlightCore re-exports FlightConfig.
@_exported import struct HTTPTypes.HTTPRequest
@_exported import struct HTTPTypes.HTTPResponse
@_exported import struct HTTPTypes.HTTPField
@_exported import struct HTTPTypes.HTTPFields

/// Encodes a handler's return value (§4). A free function rather than a
/// bare method call in the macro expansion so a non-conforming return type
/// fails with a diagnostic that names `ResponseEncodable` at the handler.
public func encodeResponse<T: ResponseEncodable>(
    _ value: T,
    for context: RequestContext
) throws -> Response {
    try value.response(for: context)
}

extension RouteRegistration {
    /// Codegen convenience: macro expansions carry the method as the literal
    /// they validated ("GET"); user code should prefer the typed initializer.
    public init(
        method: String,
        path: String,
        kind: Kind = .http,
        source: String = "<direct>",
        handler: @escaping @Sendable (RequestContext) async throws -> Response
    ) {
        self.init(
            method: HTTPRequest.Method(method) ?? .get,
            path: path,
            kind: kind,
            source: source,
            handler: handler
        )
    }
}
