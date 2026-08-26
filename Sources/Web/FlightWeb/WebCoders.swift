import FlightCore
import Foundation
import HTTPTypes

/// How this application turns values into response bodies, request bodies
/// into values, and errors into either.
///
/// Every one of these was previously hardcoded: a bare `JSONEncoder()` for
/// responses, a bare `JSONDecoder()` for request bodies, and a fixed
/// `{"status": …, "error": …}` object for failures. That made Flight
/// unusable for the common case of an API whose clients expect `snake_case`
/// keys or ISO-8601 timestamps, with no way to argue — and `ResponseEncodable`,
/// the whole point of returning a domain type from a handler, unusable with it.
///
/// Registered by ``FlightWebModule`` from `flight.yaml`, and reachable from
/// any handler as `context.coders`. Register your own to override:
///
/// ```swift
/// container.register(WebCoders.self, scope: .singleton) { _ in
///     var coders = WebCoders.default
///     coders.jsonEncoder.keyEncodingStrategy = .convertToSnakeCase
///     return coders
/// }
/// ```
public struct WebCoders: Sendable {
    /// Encodes handler return values and `Response.json` bodies.
    public var jsonEncoder: JSONEncoder
    /// Decodes `body:` handler parameters.
    public var jsonDecoder: JSONDecoder
    /// Decodes `application/x-www-form-urlencoded` `body:` parameters —
    /// what an HTML form (or an OAuth token request) posts. See
    /// ``FormDecoder`` for the wire semantics.
    public var formDecoder: FormDecoder
    /// Turns a status and a client-safe message into a response.
    ///
    /// A closure rather than a format enum, so an application whose clients
    /// expect something other than JSON — or something with more fields than
    /// RFC 9457 names — can say so without Flight enumerating the options in
    /// advance.
    public var renderError: @Sendable (HTTPResponse.Status, String) -> Response

    public init(
        jsonEncoder: JSONEncoder,
        jsonDecoder: JSONDecoder,
        formDecoder: FormDecoder = FormDecoder(),
        renderError: @escaping @Sendable (HTTPResponse.Status, String) -> Response
    ) {
        self.jsonEncoder = jsonEncoder
        self.jsonDecoder = jsonDecoder
        self.formDecoder = formDecoder
        self.renderError = renderError
    }

    /// What an application gets without configuring anything.
    ///
    /// Dates are ISO-8601 rather than Foundation's default, which is seconds
    /// since 2001 as a bare `Double`. That default is nearly always wrong on
    /// a wire shared with anything that is not another Foundation client, and
    /// silently so — the field is present and numeric, just meaningless to
    /// the reader.
    public static var `default`: WebCoders {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return WebCoders(
            jsonEncoder: encoder,
            jsonDecoder: decoder,
            renderError: ProblemDetails.render)
    }
}

/// RFC 9457 `application/problem+json` — the standard shape for an HTTP error
/// body, and what Flight answers with unless told otherwise.
///
/// ```json
/// {"status": 404, "title": "Not Found", "detail": "no user 7f3a…"}
/// ```
///
/// `title` is the status's own reason phrase and `detail` the message the
/// handler chose; `type` is omitted, which RFC 9457 says a consumer must read
/// as `about:blank`. Nothing here ever carries an underlying error's text —
/// that goes to the log, not the client.
public enum ProblemDetails {
    struct Body: Encodable {
        let status: Int
        let title: String
        let detail: String?
    }

    /// The default ``WebCoders/renderError``.
    public static let render: @Sendable (HTTPResponse.Status, String) -> Response = { status, message in
        let body = Body(
            status: status.code,
            title: status.reasonPhrase,
            detail: message == status.reasonPhrase ? nil : message)
        // A three-field struct of primitives cannot fail to encode; the
        // fallback keeps this total rather than trapping on the impossible.
        guard let data = try? JSONEncoder().encode(body) else {
            return .status(status)
        }
        var headers: HTTPFields = [:]
        headers[.contentType] = "application/problem+json"
        return .fixed(status: status, headers: headers, body: data)
    }
}

extension RequestContext {
    /// This application's coders, or the defaults when nothing registered any
    /// — so a hand-built context (a unit test, a mock) still encodes.
    public var coders: WebCoders {
        (try? resolve(WebCoders.self)) ?? .default
    }
}

extension WebCoders {
    /// Builds the coders from `web.*` configuration.
    ///
    /// ```yaml
    /// web:
    ///   json:
    ///     key-strategy: snake-case     # snake-case | as-is
    ///     date-strategy: iso8601       # iso8601 | seconds | milliseconds | foundation
    ///     pretty-print: false
    ///   errors:
    ///     format: problem              # problem | simple
    /// ```
    public init(configuration: FlightCore.Configuration) throws {
        var coders = WebCoders.default

        switch try configuration.getIfPresent("web.json.key-strategy", as: String.self) ?? "as-is" {
        case "as-is":
            break
        case "snake-case":
            coders.jsonEncoder.keyEncodingStrategy = .convertToSnakeCase
            coders.jsonDecoder.keyDecodingStrategy = .convertFromSnakeCase
        case let other:
            throw WebCodersError.unknownValue(
                key: "web.json.key-strategy", value: other, supported: ["as-is", "snake-case"])
        }

        switch try configuration.getIfPresent("web.json.date-strategy", as: String.self)
            ?? "iso8601"
        {
        case "iso8601":
            break  // already the default
        case "seconds":
            coders.jsonEncoder.dateEncodingStrategy = .secondsSince1970
            coders.jsonDecoder.dateDecodingStrategy = .secondsSince1970
        case "milliseconds":
            coders.jsonEncoder.dateEncodingStrategy = .millisecondsSince1970
            coders.jsonDecoder.dateDecodingStrategy = .millisecondsSince1970
        case "foundation":
            coders.jsonEncoder.dateEncodingStrategy = .deferredToDate
            coders.jsonDecoder.dateDecodingStrategy = .deferredToDate
        case let other:
            throw WebCodersError.unknownValue(
                key: "web.json.date-strategy", value: other,
                supported: ["iso8601", "seconds", "milliseconds", "foundation"])
        }

        if try configuration.getIfPresent("web.json.pretty-print", as: Bool.self) ?? false {
            coders.jsonEncoder.outputFormatting.insert(.prettyPrinted)
        }

        switch try configuration.getIfPresent("web.errors.format", as: String.self) ?? "problem" {
        case "problem":
            break  // already the default
        case "simple":
            coders.renderError = SimpleErrorBody.render
        case let other:
            throw WebCodersError.unknownValue(
                key: "web.errors.format", value: other, supported: ["problem", "simple"])
        }

        self = coders
    }
}

/// The pre-RFC-9457 shape Flight used to hardcode, kept for applications
/// whose clients already parse it: `{"status": 404, "error": "Not Found"}`.
public enum SimpleErrorBody {
    struct Body: Encodable {
        let status: Int
        let error: String
    }

    public static let render: @Sendable (HTTPResponse.Status, String) -> Response = { status, message in
        guard let data = try? JSONEncoder().encode(Body(status: status.code, error: message))
        else {
            return .status(status)
        }
        var headers: HTTPFields = [:]
        headers[.contentType] = ContentType.json.rawValue
        return .fixed(status: status, headers: headers, body: data)
    }
}

/// A `web.*` key whose value Flight does not recognize. Raised at startup,
/// naming the key, the value, and what would have been accepted.
public enum WebCodersError: Error, CustomStringConvertible {
    case unknownValue(key: String, value: String, supported: [String])

    public var description: String {
        switch self {
        case .unknownValue(let key, let value, let supported):
            return "\(key) is \"\(value)\"; expected one of \(supported.joined(separator: ", "))."
        }
    }
}
