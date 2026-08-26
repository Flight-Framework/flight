import Foundation
import HTTPTypes

/// An error that knows its own HTTP shape. Thrown from anywhere in the
/// middleware chain or a handler; `errorResponse(for:context:)` renders it.
/// Errors *not* conforming render as an opaque 500 — internal detail never
/// leaks to the wire, only to `context.logger`.
public protocol HTTPErrorRepresentable: Error {
    var httpStatus: HTTPResponse.Status { get }
    /// Client-visible message. Keep it safe for the wire.
    var httpMessage: String { get }
}

/// The general-purpose throwable HTTP error.
///
///     throw HTTPError(.forbidden)
///     throw HTTPError(.unprocessableContent, "name must not be empty")
public struct HTTPError: HTTPErrorRepresentable, Sendable {
    public let httpStatus: HTTPResponse.Status
    public let httpMessage: String

    public init(_ status: HTTPResponse.Status, _ message: String? = nil) {
        self.httpStatus = status
        self.httpMessage = message ?? status.reasonPhrase
    }
}

/// Routing-layer failures (§4).
public enum RoutingError: HTTPErrorRepresentable, Sendable, Equatable {
    /// A handler asked for a path parameter its own pattern doesn't bind —
    /// a programming error in the route, surfaced as a 500, never a 4xx.
    case missingPathParameter(String)

    public var httpStatus: HTTPResponse.Status {
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
    public let httpStatus: HTTPResponse.Status = .badRequest
    public let httpMessage: String

    public init(_ message: String) {
        self.httpMessage = "Invalid request body: \(message)"
    }
}

/// A request body arrived in a format this route does not speak — the
/// client's 415, naming both what came in and what would have worked.
public struct UnsupportedMediaTypeError: HTTPErrorRepresentable, Sendable {
    public let httpStatus: HTTPResponse.Status = .unsupportedMediaType
    public let httpMessage: String

    public init(received: String, accepted: [String]) {
        self.httpMessage =
            "Unsupported Media Type: '\(received)' — this route accepts \(accepted.joined(separator: " or "))"
    }
}

/// Decodes a request body into `type` (§4's `body:` handler parameter),
/// negotiated on the request's `Content-Type`:
///
/// | `Content-Type` | decoder |
/// |---|---|
/// | absent | JSON — the long-documented leniency for curl and tests |
/// | `application/json`, any `+json` suffix | ``WebCoders/jsonDecoder`` |
/// | `application/x-www-form-urlencoded` | ``WebCoders/formDecoder`` |
/// | anything else, or unparseable | **415**, naming both sides |
///
/// Breaking change in 0.6.0, on purpose: a JSON body mislabeled
/// `text/plain` used to decode and now answers 415. The absent-header case
/// keeps working precisely so that hand-written clients don't churn; a
/// *wrong* label is a client bug this framework stopped papering over.
///
/// A `charset` parameter on the form type must be `utf-8` (or `us-ascii`,
/// its subset) — the only encodings the decoder reads.
public func decodeRequestBody<T: Decodable>(
    _ type: T.Type = T.self,
    from context: RequestContext
) throws -> T {
    guard !context.request.body.isEmpty else {
        throw BodyDecodingError("expected a request body, got an empty one")
    }
    // Negotiation outside the decode's error wrapping: its 415 must reach
    // the wire as itself, never rewrapped into a decoding 400.
    let format = try negotiatedBodyFormat(of: context.request)
    do {
        switch format {
        case .json:
            return try context.coders.jsonDecoder.decode(type, from: context.request.body)
        case .form:
            return try context.coders.formDecoder.decode(type, from: context.request.body)
        }
    } catch let error as DecodingError {
        throw BodyDecodingError(error.shortDescription)
    } catch {
        throw BodyDecodingError(String(describing: error))
    }
}

/// The raw-bytes escape hatch: a `body: Data` handler parameter receives
/// the request body verbatim — any `Content-Type`, no negotiation, empty
/// allowed. Resolved by overload over the generic `Decodable` form, which
/// would otherwise demand base64-in-quotes from a client sending
/// `application/octet-stream`.
public func decodeRequestBody(
    _ type: Data.Type = Data.self,
    from context: RequestContext
) throws -> Data {
    context.request.body
}

/// The plain-text form: a `body: String` handler parameter receives the
/// body as UTF-8 text — any `Content-Type` (the *label* is not enforced;
/// the *bytes* are strictly validated, and invalid UTF-8 is a 400). A
/// `charset` parameter naming anything but `utf-8`/`us-ascii` is a 415:
/// the client declared an encoding this decoder would silently misread.
public func decodeRequestBody(
    _ type: String.Type = String.self,
    from context: RequestContext
) throws -> String {
    if let raw = context.request.headers[.contentType],
        let media = MediaType(parsing: raw),
        let charset = media.parameter("charset"),
        !["utf-8", "us-ascii"].contains(charset.lowercased())
    {
        throw UnsupportedMediaTypeError(
            received: "\(media.essence); charset=\(charset)",
            accepted: ["charset=utf-8"])
    }
    guard let text = String(data: context.request.body, encoding: .utf8) else {
        throw BodyDecodingError("request body is not valid UTF-8")
    }
    return text
}

enum NegotiatedBodyFormat {
    case json
    case form
}

func negotiatedBodyFormat(of request: Request) throws -> NegotiatedBodyFormat {
    let acceptedTypes = ["application/json", "application/x-www-form-urlencoded"]
    guard let raw = request.headers[.contentType] else { return .json }
    guard let media = MediaType(parsing: raw) else {
        throw UnsupportedMediaTypeError(received: raw, accepted: acceptedTypes)
    }
    if media.isJSON { return .json }
    if media.essence == "application/x-www-form-urlencoded" {
        if let charset = media.parameter("charset"),
            !["utf-8", "us-ascii"].contains(charset.lowercased())
        {
            throw UnsupportedMediaTypeError(
                received: "\(media.essence); charset=\(charset)",
                accepted: ["charset=utf-8"])
        }
        return .form
    }
    throw UnsupportedMediaTypeError(received: media.essence, accepted: acceptedTypes)
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
