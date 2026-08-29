import Foundation
import HTTPTypes

/// Return-type encoding for handlers (§4): conceptually parallel to Flight
/// Config's `ConfigDecodable` — primitives ship built-in, custom types
/// conform the same way any Codable-adjacent type would:
///
///     struct UserResponse: Codable, ResponseEncodable {}   // JSON, 200
///
/// HTTPResponse.Status-code inference: values encode as 200 by default; `Void` handlers
/// answer 204; `nil` optionals answer 404. Anything else returns `Response`
/// directly (or uses `Response.json(_:status:)`).
///
/// Deliberately not `Sendable`-refining: a handler's return value is encoded
/// inside the handler thunk, on the same task — only the resulting
/// `Response` ever crosses a concurrency boundary.
public protocol ResponseEncodable {
    func response(for context: RequestContext) throws -> Response
}

/// Identity — handlers returning `Response` pass through untouched.
extension Response: ResponseEncodable {
    public func response(for context: RequestContext) throws -> Response { self }
}

/// The default for domain types: JSON body, 200, application/json.
extension ResponseEncodable where Self: Encodable {
    public func response(for context: RequestContext) throws -> Response {
        try .json(self, encoder: context.coders.jsonEncoder)
    }
}

extension String: ResponseEncodable {
    public func response(for context: RequestContext) throws -> Response {
        .text(self)
    }
}

extension Data: ResponseEncodable {
    public func response(for context: RequestContext) throws -> Response {
        .data(self)
    }
}

/// nil → 404: "the resource this handler models does not exist here."
extension Optional: ResponseEncodable where Wrapped: ResponseEncodable {
    public func response(for context: RequestContext) throws -> Response {
        switch self {
        case .some(let wrapped): return try wrapped.response(for: context)
        case .none:
            // Through the app's configured renderer, not `ProblemDetails`
            // directly: an app that set `errors.format: simple` got the
            // RFC 9457 body here and its own shape from a router 404 — the
            // same status, two shapes, depending on which produced it.
            return .problem(
                status: .notFound, message: "Not Found", render: context.coders.renderError)
        }
    }
}

extension Array: ResponseEncodable where Element: Encodable {
    public func response(for context: RequestContext) throws -> Response {
        try .json(self, encoder: context.coders.jsonEncoder)
    }
}

extension Dictionary: ResponseEncodable where Key: Encodable, Value: Encodable {
    public func response(for context: RequestContext) throws -> Response {
        // The configured encoder, like `Array` and every plain `Encodable`
        // beside it. This one used the package default, so an app configured
        // for snake-case keys or a non-default date strategy got default
        // encoding for exactly the handlers that return a dictionary.
        try .json(self, encoder: context.coders.jsonEncoder)
    }
}
