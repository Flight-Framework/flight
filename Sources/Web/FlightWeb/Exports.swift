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
        pipelines: [String] = [MiddlewareRegistration.defaultLane],
        bodyMode: BodyMode = .buffered(maxBytes: nil),
        handler: @escaping @Sendable (RequestContext) async throws -> Response
    ) {
        // A method string this does not recognize is a build-generator bug
        // or a typo, and `?? .get` turned either into a *live GET route* —
        // reachable, wrong, and silent. Everything else about the route table
        // fails at startup; so does this.
        guard let parsed = HTTPRequest.Method(method) else {
            preconditionFailure(
                """
                Route \(source) declares HTTP method "\(method)" for \(path), which is not a \
                valid method token. Registering it as GET — which is what used to happen — \
                would publish a route nobody asked for.
                """)
        }
        self.init(
            method: parsed,
            path: path,
            kind: kind,
            source: source,
            pipelines: pipelines,
            bodyMode: bodyMode,
            handler: handler
        )
    }
}
