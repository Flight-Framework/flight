import Foundation
import HTTPTypes

/// Return-type encoding for handlers (§4): conceptually parallel to Flight
/// Config's `ConfigDecodable` — primitives ship built-in, custom types
/// conform the same way any Codable-adjacent type would:
///
///     struct UserResponse: Codable, ResponseEncodable {}   // JSON, 200
///
/// Status-code inference: values encode as 200 by default; `Void` handlers
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
        try .json(self)
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
        case .none: return .problem(status: .notFound, message: "Not Found")
        }
    }
}

extension Array: ResponseEncodable where Element: Encodable {
    public func response(for context: RequestContext) throws -> Response {
        try .json(self)
    }
}

extension Dictionary: ResponseEncodable where Key: Encodable, Value: Encodable {
    public func response(for context: RequestContext) throws -> Response {
        try .json(self)
    }
}
