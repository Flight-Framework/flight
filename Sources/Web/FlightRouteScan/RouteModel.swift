import SwiftSyntax

/// The route attributes `@Controller` consumes, and what each means.
public enum RouteKind: String, CaseIterable {
    case get = "GetRoute"
    case post = "PostRoute"
    case put = "PutRoute"
    case patch = "PatchRoute"
    case delete = "DeleteRoute"
    case webSocket = "WebSocketRoute"

    public var httpMethod: String {
        switch self {
        case .get: return "GET"
        case .post: return "POST"
        case .put: return "PUT"
        case .patch: return "PATCH"
        case .delete: return "DELETE"
        case .webSocket: return "GET"  // upgrades ride a GET (RFC 6455 §4.1)
        }
    }

    public var isUpgrade: Bool { self == .webSocket }
}

/// One mapped handler method, as scanned from the controller body.
public struct ScannedRoute {
    public let kind: RouteKind
    /// The path pattern's literal content ("/users/:id").
    public let path: String
    public let methodName: String
    /// Has a second, `body:`-labeled parameter of this type.
    public let bodyTypeText: String?
    /// The `maxBodyBytes:` argument's source text, verbatim — nil means
    /// the transport default.
    public let maxBodyBytesText: String?
    /// The route's own `pipelines:` argument, verbatim. nil means the route
    /// said nothing and inherits the controller's lanes; non-nil *replaces*
    /// them.
    public let pipelinesText: String?
    /// Where to point a diagnostic about this route's lanes.
    public let attribute: AttributeSyntax
    /// A `body: RequestBodyStream` parameter — the route is
    /// streaming-bodied and the transport must not buffer it.
    public var isStreamingBody: Bool {
        bodyTypeText == "RequestBodyStream" || bodyTypeText == "FlightWeb.RequestBodyStream"
    }
    public let isAsync: Bool
    public let isThrows: Bool
    /// nil ⇔ no return value (handler answers 204).
    public let returnTypeText: String?
    public let node: FunctionDeclSyntax
}

public enum RouteScanning {

    /// The route attributes attached to `function`, with their literal
    /// paths. Diagnoses (and skips) non-literal paths — the route table is
    /// compile-time information (§4), so a computed path is a build error.
    public static func mappingAttributes(
        of function: FunctionDeclSyntax,
        diagnostics: some RouteDiagnostics
    ) -> [(
        kind: RouteKind, path: String, maxBodyBytes: String?, pipelines: String?,
        attribute: AttributeSyntax
    )] {
        var found: [(RouteKind, String, String?, String?, AttributeSyntax)] = []
        for element in function.attributes {
            guard let attribute = element.as(AttributeSyntax.self),
                  let name = attribute.attributeName.as(IdentifierTypeSyntax.self)?.name.text,
                  let kind = RouteKind(rawValue: name)
            else { continue }
            guard let path = literalPath(of: attribute) else {
                diagnostics.error(
                    "route.nonliteral",
                    "@\(name) requires a string-literal path — the route table is built at compile time (§4).",
                    at: attribute
                )
                continue
            }
            found.append((
                kind, path,
                labeledArgumentText(of: attribute, named: "maxBodyBytes"),
                labeledArgumentText(of: attribute, named: "pipelines"),
                attribute))
        }
        return found
    }

    /// A labeled argument's source text, verbatim — re-embedded into the
    /// generated registration the way `@Controller(pipelines:)` is, so
    /// constants and expressions both work.
    private static func labeledArgumentText(
        of attribute: AttributeSyntax, named label: String
    ) -> String? {
        guard let arguments = attribute.arguments?.as(LabeledExprListSyntax.self) else {
            return nil
        }
        for argument in arguments where argument.label?.text == label {
            return argument.expression.trimmedDescription
        }
        return nil
    }

    /// The path argument's literal content, or nil for anything that is not
    /// a plain (non-interpolated) string literal.
    private static func literalPath(of attribute: AttributeSyntax) -> String? {
        guard let arguments = attribute.arguments?.as(LabeledExprListSyntax.self),
              let first = arguments.first, first.label == nil,
              let literal = first.expression.as(StringLiteralExprSyntax.self)
        else { return nil }
        var path = ""
        for segment in literal.segments {
            guard let text = segment.as(StringSegmentSyntax.self) else { return nil }
            path += text.content.text
        }
        return path
    }

    /// Validates a mapped method's shape and returns the scanned routes, or
    /// [] after diagnosing. Accepted shapes (any async/throws combination):
    ///
    ///     func f(_ context: RequestContext) [async] [throws] [-> T]
    ///     func f(_ context: RequestContext, body: B) [async] [throws] [-> T]
    public static func scanRoutes(
        of function: FunctionDeclSyntax,
        diagnostics: some RouteDiagnostics
    ) -> [ScannedRoute] {
        let mappings = mappingAttributes(of: function, diagnostics: diagnostics)
        guard !mappings.isEmpty else { return [] }

        // Path validation lives here, where the routes are actually built,
        // rather than in the peer marker macro — which also scanned, so every
        // mapping diagnostic was emitted twice at the identical location.
        for mapping in mappings {
            validatePath(
                mapping.path, name: mapping.kind.rawValue,
                at: mapping.attribute, diagnostics: diagnostics)
            // A path is re-embedded into generated string literals verbatim,
            // so a `"` or `\` in one produced a compile error inside an
            // expansion the author cannot see, at a line they did not write.
            // Neither belongs in a URL path anyway.
            if mapping.path.contains("\"") || mapping.path.contains("\\") {
                diagnostics.error(
                    "route.path",
                    """
                    @\(mapping.kind.rawValue) path "\(mapping.path)" contains a quote or a \
                    backslash. Neither is legal unescaped in a URL path; percent-encode it \
                    if it is genuinely part of the path.
                    """,
                    at: mapping.attribute
                )
                return []
            }
        }

        let name = function.name.text

        let isTypeLevel = function.modifiers.contains {
            $0.name.tokenKind == .keyword(.static) || $0.name.tokenKind == .keyword(.class)
        }
        if isTypeLevel {
            diagnostics.error(
                "route.static",
                "Route handler '\(name)' must be an instance method — the route factory constructs a controller instance to call it on.",
                at: function
            )
            return []
        }
        if function.modifiers.contains(where: { $0.name.tokenKind == .keyword(.mutating) }) {
            diagnostics.error(
                "route.mutating",
                "Route handler '\(name)' must not be mutating — the controller component is shared across requests.",
                at: function
            )
            return []
        }

        let parameters = Array(function.signature.parameterClause.parameters)
        guard let first = parameters.first,
              first.firstName.tokenKind == .wildcard,
              typeName(first.type).hasSuffix("RequestContext")
        else {
            diagnostics.error(
                "route.signature",
                "Route handler '\(name)' must take '_ context: RequestContext' as its first parameter.",
                at: function
            )
            return []
        }

        var bodyTypeText: String? = nil
        if parameters.count >= 2 {
            let second = parameters[1]
            guard parameters.count == 2, second.firstName.text == "body" else {
                diagnostics.error(
                    "route.signature",
                    "Route handler '\(name)' may take at most one extra parameter, labeled 'body:', decoded from the request body.",
                    at: function
                )
                return []
            }
            bodyTypeText = second.type.trimmedDescription
        }

        let effects = function.signature.effectSpecifiers
        let returnTypeText = function.signature.returnClause?.type.trimmedDescription
        let returnType = returnTypeText.flatMap { $0 == "Void" || $0 == "()" ? nil : $0 }

        // Two shapes an upgrade route cannot have, both of which used to fail
        // as compile errors inside the expansion — or, for the body, not at
        // all until a runtime refusal nobody could explain.
        for mapping in mappings where mapping.kind.isUpgrade {
            if bodyTypeText != nil {
                diagnostics.error(
                    "route.upgradebody",
                    """
                    A @\(mapping.kind.rawValue) handler cannot take a 'body:' parameter: an \
                    upgrade request has an empty body by construction (RFC 6455 §4.1), so \
                    decoding one always fails and the upgrade is always refused at runtime. \
                    Read what you need from the request's headers or query.
                    """,
                    at: mapping.attribute
                )
                return []
            }
            // Only the definitely-wrong case is diagnosable here: a
            // concrete conforming type is a legitimate return type, so the
            // rest is the type checker's — it just used to report inside the
            // expansion rather than at the handler.
            guard returnType != nil else {
                diagnostics.error(
                    "route.upgradereturn",
                    """
                    A @\(mapping.kind.rawValue) handler must return something conforming to \
                    WebSocketUpgradeHandler — that is what the generated route hands the \
                    transport. This one returns nothing, so there is no connection to \
                    upgrade to.
                    """,
                    at: function
                )
                return []
            }
        }

        return mappings.map { kind, path, maxBodyBytes, pipelines, attribute in
            ScannedRoute(
                kind: kind,
                path: path,
                methodName: name,
                bodyTypeText: bodyTypeText,
                maxBodyBytesText: maxBodyBytes,
                pipelinesText: pipelines,
                attribute: attribute,
                isAsync: effects?.asyncSpecifier != nil,
                isThrows: effects?.throwsClause != nil,
                returnTypeText: returnType,
                node: function
            )
        }
    }

    /// The `@Controller` base path — its first, unlabeled string-literal
    /// argument. Empty for `@Controller` with no path, and for `nil`.
    public static func basePath(
        of node: AttributeSyntax,
        diagnostics: some RouteDiagnostics
    ) -> String {
        guard let arguments = node.arguments?.as(LabeledExprListSyntax.self),
              let first = arguments.first, first.label == nil
        else { return "" }
        if first.expression.trimmedDescription == "nil" { return "" }
        guard let literal = first.expression.as(StringLiteralExprSyntax.self) else {
            diagnostics.error(
                "controller.path.nonliteral",
                "@Controller's path must be a string literal — the route table is built at compile time (§4).",
                at: first.expression
            )
            return ""
        }
        var path = ""
        for segment in literal.segments {
            guard let text = segment.as(StringSegmentSyntax.self) else {
                diagnostics.error(
                    "controller.path.nonliteral",
                    "@Controller's path must be a plain string literal, with no interpolation.",
                    at: first.expression
                )
                return ""
            }
            path += text.content.text
        }
        guard !path.isEmpty, path != "/" else { return "" }
        guard path.hasPrefix("/") else {
            diagnostics.error(
                "controller.path",
                "@Controller path '\(path)' must start with '/'.",
                at: node
            )
            return ""
        }
        return path
    }

    /// The lanes a route actually runs through: its own `pipelines:` when it
    /// has one, otherwise its controller's.
    ///
    /// Replacement, not concatenation, and that is the whole rule — it is the
    /// only shape that expresses both directions, a public controller with
    /// one authenticated route and an authenticated controller with one
    /// public route. Appending could only ever add, so it cannot say "this
    /// one is public".
    ///
    /// Shared because it is applied twice: by `@Controller`, deciding what a
    /// route registers with, and by `flight-registration-gen`, deciding what
    /// the static manifest records. Two copies of a one-line rule is exactly
    /// the shape that drifts quietly — the manifest would claim a lane the
    /// expansion never used, and nothing would catch it.
    public static func resolvedPipelines(route: String?, controller: String?) -> String? {
        route ?? controller
    }

    /// The `pipelines:` argument's source text, verbatim. A route's own
    /// `pipelines:` *replaces* this rather than adding to it.
    public static func pipelines(of node: AttributeSyntax) -> String? {
        guard let arguments = node.arguments?.as(LabeledExprListSyntax.self) else { return nil }
        for argument in arguments where argument.label?.text == "pipelines" {
            return argument.expression.trimmedDescription
        }
        return nil
    }

    private static func typeName(_ type: TypeSyntax) -> String {
        type.trimmedDescription
    }

    // MARK: - Controller base-path combination

    /// Combines a `@Controller` base path with one mapped method's own path,
    /// following Spring's `@RequestMapping` class+method combination rule:
    /// concatenate, collapsing a doubled `/` at the seam; a bare `base` or a
    /// bare `method` (either empty) yields the other unchanged; a method
    /// path of exactly `"/"` — the "no sub-path" idiom — resolves to `base`
    /// itself rather than `base` with a trailing slash appended (the two are
    /// equivalent at match time, since `Router` treats a trailing slash as
    /// insignificant, but the un-suffixed form reads better in logs and
    /// introspection).
    ///
    /// Both inputs are already known-valid patterns (each was validated
    /// independently at its own attribute site); duplicate parameter names
    /// or a non-trailing `**` introduced *by* the combination are still
    /// checked — by the same `RoutePattern` parse every route goes through
    /// at `Router.init` (Flight Core's established split: per-literal syntax
    /// is a macro-time diagnostic, conflicts across combination are a
    /// startup error, same as cross-controller route conflicts already are).
    public static func combinePaths(_ base: String, _ method: String) -> String {
        guard !base.isEmpty else { return method }
        guard !method.isEmpty, method != "/" else { return base }
        let baseEndsWithSlash = base.hasSuffix("/")
        let methodStartsWithSlash = method.hasPrefix("/")
        if baseEndsWithSlash && methodStartsWithSlash {
            return base + method.dropFirst()
        } else if baseEndsWithSlash || methodStartsWithSlash {
            return base + method
        } else {
            return base + "/" + method
        }
    }

    /// Pattern-syntax validation at compile time (§4: "path-pattern validity
    /// becomes information the build has before the binary exists"). Kept in
    /// lockstep with the runtime `RoutePattern` parser — these rules are the
    /// same ones it enforces.
    public static func validatePath(
        _ path: String,
        name: String,
        at node: AttributeSyntax,
        diagnostics: some RouteDiagnostics
    ) {
        guard path.hasPrefix("/") else {
            diagnostics.error(
                "route.path",
                "@\(name) path '\(path)' must start with '/'.",
                at: node
            )
            return
        }
        let segments = path.split(separator: "/", omittingEmptySubsequences: true)
        var seenParameters: Set<String> = []
        for (index, segment) in segments.enumerated() {
            if segment == "**" {
                if index != segments.count - 1 {
                    diagnostics.error(
                        "route.path",
                        "@\(name) path '\(path)': '**' is only allowed as the final segment.",
                        at: node
                    )
                }
            } else if segment.hasPrefix(":") {
                let parameter = String(segment.dropFirst())
                if parameter.isEmpty {
                    diagnostics.error(
                        "route.path",
                        "@\(name) path '\(path)' has a ':' segment with no parameter name.",
                        at: node
                    )
                } else if !seenParameters.insert(parameter).inserted {
                    diagnostics.error(
                        "route.path",
                        "@\(name) path '\(path)' binds ':\(parameter)' more than once.",
                        at: node
                    )
                }
            }
        }
    }
}
