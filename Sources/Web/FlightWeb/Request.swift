import Foundation
import HTTPTypes

/// An HTTP request as Flight Web sees it (§2, §5): the parsed head from
/// HTTPTypes plus a fully buffered body. Transports produce these at the
/// byte boundary; nothing downstream re-parses raw HTTP.
///
/// The body is buffered by default (the transport enforces a size cap and
/// rejects oversized bodies with 413 before dispatch ever runs); a route
/// that takes `body: RequestBodyStream` opts into streaming delivery, and
/// its bytes arrive via ``bodyStream`` instead.
public struct Request: Sendable {
    /// Method, target, and header fields — HTTPTypes' representation (§5).
    public var head: HTTPRequest
    /// The complete request body. Empty for bodyless requests — and empty
    /// for streaming-bodied routes, whose bytes arrive via ``bodyStream``.
    public var body: Data
    var _bodyStream: BodyStreamBox?

    public init(head: HTTPRequest, body: Data = Data()) {
        self.head = head
        self.body = body
    }

    /// Convenience initializer used by tests and in-process clients.
    public init(
        method: HTTPRequest.Method = .get,
        path: String,
        headers: HTTPFields = [:],
        body: Data = Data()
    ) {
        self.head = HTTPRequest(
            method: method,
            scheme: nil,
            authority: nil,
            path: path,
            headerFields: headers
        )
        self.body = body
    }

    // MARK: - Head accessors

    public var method: HTTPRequest.Method { head.method }
    public var headers: HTTPFields { head.headerFields }

    /// The full request target as sent, query string included ("/users?x=1").
    public var uri: String { head.path ?? "/" }

    /// The path component only, percent-encoding left intact — the router
    /// decodes per segment so an encoded "/" cannot change route structure.
    public var path: String {
        let target = uri
        if let separator = target.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            return String(target[..<separator])
        }
        return target
    }

    // MARK: - Query

    /// Query items in order of appearance, percent-decoded. Repeated keys are
    /// preserved ("?tag=a&tag=b" yields two entries).
    public var queryItems: [(name: String, value: String)] {
        Self.queryPairs(of: uri).compactMap { pair in
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let name = Self.decodeQueryComponent(parts[0]) else { return nil }
            let value = parts.count > 1 ? Self.decodeQueryComponent(parts[1]) : ""
            guard let value else { return nil }
            return (name, value)
        }
    }

    /// First value for a query parameter, or nil.
    ///
    /// Scans the query string for the name rather than going through
    /// ``queryItems``, which decodes and allocates every pair — a handler
    /// reading three parameters parsed the whole query three times and threw
    /// away three arrays.
    public func queryParam(_ name: String) -> String? {
        for pair in Self.queryPairs(of: uri) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard Self.decodeQueryComponent(parts[0]) == name else { continue }
            return parts.count > 1 ? Self.decodeQueryComponent(parts[1]) : ""
        }
        return nil
    }

    /// The undecoded `name=value` runs of a URI's query, in order.
    private static func queryPairs(of target: String) -> [Substring] {
        guard let queryStart = target.firstIndex(of: "?") else { return [] }
        var query = target[target.index(after: queryStart)...]
        if let fragmentStart = query.firstIndex(of: "#") {
            query = query[..<fragmentStart]
        }
        guard !query.isEmpty else { return [] }
        return query.split(separator: "&", omittingEmptySubsequences: true)
    }

    /// application/x-www-form-urlencoded semantics: "+" is a space.
    private static func decodeQueryComponent(_ component: Substring) -> String? {
        component
            .replacingOccurrences(of: "+", with: " ")
            .removingPercentEncoding
    }
}
