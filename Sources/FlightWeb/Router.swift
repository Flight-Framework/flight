import Foundation
import HTTPTypes

/// A parsed path pattern: static segments and `:name` parameters.
public struct RoutePattern: Sendable, Equatable, CustomStringConvertible {
    public enum Segment: Sendable, Equatable {
        case constant(String)
        case parameter(String)
        /// Trailing `**`: matches the rest of the path (one or more
        /// segments), bound as "**" in pathParameters.
        case catchAll
    }

    public let segments: [Segment]
    public let source: String

    public enum PatternError: Error, CustomStringConvertible, Equatable {
        case mustStartWithSlash(String)
        case emptyParameterName(String)
        case catchAllNotTrailing(String)
        case duplicateParameter(String, name: String)

        public var description: String {
            switch self {
            case .mustStartWithSlash(let pattern):
                return "Route pattern '\(pattern)' must start with '/'."
            case .emptyParameterName(let pattern):
                return "Route pattern '\(pattern)' has a ':' segment with no name."
            case .catchAllNotTrailing(let pattern):
                return "Route pattern '\(pattern)': '**' is only allowed as the final segment."
            case .duplicateParameter(let pattern, let name):
                return "Route pattern '\(pattern)' binds ':\(name)' more than once."
            }
        }
    }

    public init(_ pattern: String) throws {
        guard pattern.hasPrefix("/") else {
            throw PatternError.mustStartWithSlash(pattern)
        }
        var segments: [Segment] = []
        var seenNames: Set<String> = []
        let rawSegments = pattern.split(separator: "/", omittingEmptySubsequences: true)
        for (index, raw) in rawSegments.enumerated() {
            if raw == "**" {
                guard index == rawSegments.count - 1 else {
                    throw PatternError.catchAllNotTrailing(pattern)
                }
                segments.append(.catchAll)
            } else if raw.hasPrefix(":") {
                let name = String(raw.dropFirst())
                guard !name.isEmpty else { throw PatternError.emptyParameterName(pattern) }
                guard seenNames.insert(name).inserted else {
                    throw PatternError.duplicateParameter(pattern, name: name)
                }
                segments.append(.parameter(name))
            } else {
                segments.append(.constant(String(raw)))
            }
        }
        self.segments = segments
        self.source = pattern
    }

    /// Structural identity for conflict detection: parameter *positions*
    /// matter, names don't — "/u/:a" and "/u/:b" claim the same shape.
    public var shape: String {
        "/" + segments.map { segment in
            switch segment {
            case .constant(let value): return value
            case .parameter: return ":"
            case .catchAll: return "**"
            }
        }.joined(separator: "/")
    }

    public var description: String { source }
}

/// A matched route: the entry plus the bound path parameters.
public struct RouteMatch: Sendable {
    public let route: RouteRegistration
    public let pathParameters: [String: String]
}

public enum RouterError: Error, CustomStringConvertible {
    case conflictingRoutes(method: String, shape: String, sources: [String])
    case invalidPattern(source: String, underlying: RoutePattern.PatternError)

    public var description: String {
        switch self {
        case .conflictingRoutes(let method, let shape, let sources):
            return "Conflicting routes for \(method) \(shape): declared by \(sources.joined(separator: " and "))."
        case .invalidPattern(let source, let underlying):
            return "Invalid route pattern in \(source): \(underlying)"
        }
    }
}

/// The route table (§4). Built once, post-freeze, from the collected
/// `RouteRegistration` components; immutable thereafter — matching is a pure
/// concurrent read, same discipline as Core's frozen container.
///
/// Matching semantics, in priority order per segment: constant beats
/// parameter beats catch-all. `HEAD` falls back to the `GET` route when no
/// explicit `HEAD` mapping exists (the transport suppresses the body). A
/// path that matches under a different method yields 405 with `Allow`.
public struct Router: Sendable {
    private struct Entry: Sendable {
        let pattern: RoutePattern
        let registration: RouteRegistration
    }

    /// Entries grouped by method. Linear scan in declaration order with
    /// specificity-aware comparison; route counts are build-time-known and
    /// small, and correctness/diagnosability beat a trie until a measurement
    /// says otherwise (§9's "decide with data in hand" rule).
    private let entriesByMethod: [HTTPRequest.Method: [Entry]]
    public let routes: [RouteRegistration]

    public init(routes: [RouteRegistration]) throws {
        var grouped: [HTTPRequest.Method: [Entry]] = [:]
        var claimed: [String: String] = [:]  // "METHOD shape" → source
        for registration in routes {
            let pattern: RoutePattern
            do {
                pattern = try RoutePattern(registration.path)
            } catch let error as RoutePattern.PatternError {
                throw RouterError.invalidPattern(source: registration.source, underlying: error)
            }
            let key = "\(registration.method.rawValue) \(pattern.shape)"
            if let existing = claimed[key] {
                throw RouterError.conflictingRoutes(
                    method: registration.method.rawValue,
                    shape: pattern.shape,
                    sources: [existing, registration.source]
                )
            }
            claimed[key] = registration.source
            grouped[registration.method, default: []].append(
                Entry(pattern: pattern, registration: registration)
            )
        }
        // Most-specific-first within each method: constants sort before
        // parameters position by position, catch-all last. Declaration order
        // breaks remaining ties (it can only tie between distinct shapes that
        // never compete for the same path).
        for method in grouped.keys {
            grouped[method]!.sort { Self.moreSpecific($0.pattern, than: $1.pattern) }
        }
        self.entriesByMethod = grouped
        self.routes = routes
    }

    // MARK: - Matching

    public enum Outcome: Sendable {
        case matched(RouteMatch)
        case methodNotAllowed(allow: [HTTPRequest.Method])
        case notFound
    }

    public func route(method: HTTPRequest.Method, path: String) -> Outcome {
        let segments = Self.decodedSegments(of: path)

        if let match = firstMatch(method: method, segments: segments) {
            return .matched(match)
        }
        // HEAD falls back to GET (§ RFC 9110: HEAD is GET without the body).
        if method == .head, let match = firstMatch(method: .get, segments: segments) {
            return .matched(match)
        }

        // 405: some other method matches this exact path.
        var allow: [HTTPRequest.Method] = []
        for (candidate, _) in entriesByMethod where candidate != method {
            if firstMatch(method: candidate, segments: segments) != nil {
                allow.append(candidate)
            }
        }
        if !allow.isEmpty {
            if allow.contains(.get) && !allow.contains(.head) { allow.append(.head) }
            return .methodNotAllowed(allow: allow.sorted { $0.rawValue < $1.rawValue })
        }
        return .notFound
    }

    private func firstMatch(method: HTTPRequest.Method, segments: [String]) -> RouteMatch? {
        guard let entries = entriesByMethod[method] else { return nil }
        for entry in entries {
            if let parameters = Self.match(entry.pattern, against: segments) {
                return RouteMatch(route: entry.registration, pathParameters: parameters)
            }
        }
        return nil
    }

    private static func match(_ pattern: RoutePattern, against segments: [String]) -> [String: String]? {
        var parameters: [String: String] = [:]
        var index = 0
        for patternSegment in pattern.segments {
            switch patternSegment {
            case .catchAll:
                // One or more remaining segments, rejoined.
                guard index < segments.count else { return nil }
                parameters["**"] = segments[index...].joined(separator: "/")
                return parameters
            case .constant(let expected):
                guard index < segments.count, segments[index] == expected else { return nil }
            case .parameter(let name):
                guard index < segments.count, !segments[index].isEmpty else { return nil }
                parameters[name] = segments[index]
            }
            index += 1
        }
        guard index == segments.count else { return nil }
        return parameters
    }

    /// Split first, decode each segment after — so an encoded "%2F" inside a
    /// segment can never change the path's structure.
    static func decodedSegments(of path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true)
            .map { String($0).removingPercentEncoding ?? String($0) }
    }

    /// Constants beat parameters beat catch-all, compared position by
    /// position; shorter pattern wins a full-prefix tie (it is the more
    /// exact claim for the paths both can match).
    private static func moreSpecific(_ a: RoutePattern, than b: RoutePattern) -> Bool {
        func rank(_ segment: RoutePattern.Segment) -> Int {
            switch segment {
            case .constant: return 0
            case .parameter: return 1
            case .catchAll: return 2
            }
        }
        for (left, right) in zip(a.segments, b.segments) {
            let (rl, rr) = (rank(left), rank(right))
            if rl != rr { return rl < rr }
        }
        return a.segments.count < b.segments.count
    }

    /// Whether `method` + `path` resolves to a connection-upgrade route.
    ///
    /// Answered from the route table alone — no handler runs, nothing is
    /// dispatched. A transport asks this *before* dispatching an
    /// upgrade-shaped request, because dispatching one at an ordinary HTTP
    /// route would execute that route's handler, and every side effect it
    /// has, only to discard the response it cannot use.
    public func acceptsUpgrade(method: HTTPRequest.Method, path: String) -> Bool {
        guard case .matched(let match) = route(method: method, path: path) else {
            return false
        }
        return match.route.kind == .upgrade
    }

    // MARK: - Routing as the innermost responder

    /// Routing is the terminal of the pipeline, not a layer of it: it matches,
    /// binds path parameters, runs the handler, and answers. Nothing wraps it
    /// from the inside, so it takes no `next`.
    ///
    /// A handler error is rendered here rather than thrown onward, which is
    /// what lets every enclosing layer see a real response — a 500 is still a
    /// response, and access logging that missed them would be worse than no
    /// access logging.
    public var responder: Next {
        let router = self
        return { context in
            switch router.route(method: context.request.method, path: context.request.path) {
            case .notFound:
                return context.coders.renderError(.notFound, "Not Found")
            case .methodNotAllowed(let allow):
                let allowed = allow.map(\.rawValue).joined(separator: ", ")
                return context.coders.renderError(.methodNotAllowed, "Method Not Allowed")
                    .settingHeader(.allow, allowed)
            case .matched(let match):
                context.pathParameters = match.pathParameters
                do {
                    let response = try await match.route.handler(context)
                    context.response = response
                    return response
                } catch {
                    return errorResponse(for: error, context: context)
                }
            }
        }
    }
}
