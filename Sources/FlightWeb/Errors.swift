import Foundation
import HTTPTypes

/// An error that knows its own HTTP shape. Thrown from anywhere in the
/// middleware chain or a handler; `errorResponse(for:context:)` renders it.
/// Errors *not* conforming render as an opaque 500 — internal detail never
/// leaks to the wire, only to `context.logger`.
public protocol HTTPErrorRepresentable: Error {
    var httpStatus: Status { get }
    /// Client-visible message. Keep it safe for the wire.
    var httpMessage: String { get }
}

/// The general-purpose throwable HTTP error.
///
///     throw HTTPError(.forbidden)
///     throw HTTPError(.unprocessableContent, "name must not be empty")
public struct HTTPError: HTTPErrorRepresentable, Sendable {
    public let httpStatus: Status
    public let httpMessage: String

    public init(_ status: Status, _ message: String? = nil) {
        self.httpStatus = status
        self.httpMessage = message ?? status.reasonPhrase
    }
}

/// Routing-layer failures (§4).
public enum RoutingError: HTTPErrorRepresentable, Sendable, Equatable {
    /// A handler asked for a path parameter its own pattern doesn't bind —
    /// a programming error in the route, surfaced as a 500, never a 4xx.
    case missingPathParameter(String)

    public var httpStatus: Status {
        switch self {
        case .missingPathParameter: return .internalServerError
        }
    }

    public var httpMessage: String {
        switch self {
        case .missingPathParameter:
            return "Internal Server Error"
        }
    }

    /// The log-side detail, kept separate from the wire-side message.
    var logDescription: String {
        switch self {
        case .missingPathParameter(let name):
            return "handler asked for path parameter ':\(name)' which its route pattern does not bind"
        }
    }
}

/// Request-body decoding failures — always the client's 400, with the
/// decoder's reason included (it describes the request, not the server).
public struct BodyDecodingError: HTTPErrorRepresentable, Sendable {
    public let httpStatus: Status = .badRequest
    public let httpMessage: String

    public init(_ message: String) {
        self.httpMessage = "Invalid request body: \(message)"
    }
}

/// Decodes a JSON request body into `type` (§4's `body:` handler parameter).
/// Content-Type is not enforced — a missing header on an otherwise valid
/// JSON body is tolerated; malformed bytes are a 400 either way.
public func decodeRequestBody<T: Decodable>(
    _ type: T.Type = T.self,
    from context: RequestContext
) throws -> T {
    guard !context.request.body.isEmpty else {
        throw BodyDecodingError("expected a JSON body, got an empty one")
    }
    do {
        return try JSONDecoder().decode(type, from: context.request.body)
    } catch let error as DecodingError {
        throw BodyDecodingError(error.shortDescription)
    } catch {
        throw BodyDecodingError(String(describing: error))
    }
}

extension DecodingError {
    /// A one-line, client-appropriate rendering ("missing key 'name' at …").
    var shortDescription: String {
        func path(_ context: DecodingError.Context) -> String {
            let joined = context.codingPath.map(\.stringValue).joined(separator: ".")
            return joined.isEmpty ? "top level" : "'\(joined)'"
        }
        switch self {
        case .keyNotFound(let key, let context):
            return "missing key '\(key.stringValue)' at \(path(context))"
        case .typeMismatch(_, let context):
            return "type mismatch at \(path(context))"
        case .valueNotFound(_, let context):
            return "null value at \(path(context))"
        case .dataCorrupted(let context):
            return "malformed JSON at \(path(context))"
        @unknown default:
            return "undecodable JSON"
        }
    }
}
