import SwiftSyntax
import SwiftSyntaxMacros

/// The route attributes `@Controller` consumes, and what each means.
enum RouteKind: String, CaseIterable {
    case get = "GetRoute"
    case post = "PostRoute"
    case put = "PutRoute"
    case patch = "PatchRoute"
    case delete = "DeleteRoute"
    case webSocket = "WebSocketRoute"

    var httpMethod: String {
        switch self {
        case .get: return "GET"
        case .post: return "POST"
        case .put: return "PUT"
        case .patch: return "PATCH"
        case .delete: return "DELETE"
        case .webSocket: return "GET"  // upgrades ride a GET (RFC 6455 §4.1)
        }
    }

    var isUpgrade: Bool { self == .webSocket }
}

/// One mapped handler method, as scanned from the controller body.
struct ScannedRoute {
    let kind: RouteKind
    /// The path pattern's literal content ("/users/:id").
    let path: String
    let methodName: String
    /// Has a second, `body:`-labeled parameter of this type.
    let bodyTypeText: String?
    /// The `maxBodyBytes:` argument's source text, verbatim — nil means
    /// the transport default.
    let maxBodyBytesText: String?
    /// A `body: RequestBodyStream` parameter — the route is
    /// streaming-bodied and the transport must not buffer it.
    var isStreamingBody: Bool {
        bodyTypeText == "RequestBodyStream" || bodyTypeText == "FlightWeb.RequestBodyStream"
    }
    let isAsync: Bool
    let isThrows: Bool
    /// nil ⇔ no return value (handler answers 204).
    let returnTypeText: String?
    let node: FunctionDeclSyntax
}

enum RouteScanning {

    /// The route attributes attached to `function`, with their literal
    /// paths. Diagnoses (and skips) non-literal paths — the route table is
    /// compile-time information (§4), so a computed path is a build error.
    static func mappingAttributes(
        of function: FunctionDeclSyntax,
        in context: some MacroExpansionContext
    ) -> [(kind: RouteKind, path: String, maxBodyBytes: String?, attribute: AttributeSyntax)] {
        var found: [(RouteKind, String, String?, AttributeSyntax)] = []
        for element in function.attributes {
            guard let attribute = element.as(AttributeSyntax.self),
                  let name = attribute.attributeName.as(IdentifierTypeSyntax.self)?.name.text,
                  let kind = RouteKind(rawValue: name)
            else { continue }
            guard let path = literalPath(of: attribute) else {
                context.diagnoseError(
                    "route.nonliteral",
                    "@\(name) requires a string-literal path — the route table is built at compile time (§4).",
                    at: attribute
                )
                continue
            }
            found.append((kind, path, labeledArgumentText(of: attribute, named: "maxBodyBytes"), attribute))
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
    static func scanRoutes(
        of function: FunctionDeclSyntax,
        in context: some MacroExpansionContext
    ) -> [ScannedRoute] {
        let mappings = mappingAttributes(of: function, in: context)
        guard !mappings.isEmpty else { return [] }

        // Path validation lives here, where the routes are actually built,
        // rather than in the peer marker macro — which also scanned, so every
        // mapping diagnostic was emitted twice at the identical location.
        for mapping in mappings {
            validatePath(
                mapping.path, name: mapping.kind.rawValue,
                at: mapping.attribute, in: context)
            // A path is re-embedded into generated string literals verbatim,
            // so a `"` or `\` in one produced a compile error inside an
            // expansion the author cannot see, at a line they did not write.
            // Neither belongs in a URL path anyway.
            if mapping.path.contains("\"") || mapping.path.contains("\\") {
                context.diagnoseError(
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
            context.diagnoseError(
                "route.static",
                "Route handler '\(name)' must be an instance method — the container resolves the controller instance per registration.",
                at: function
            )
            return []
        }
        if function.modifiers.contains(where: { $0.name.tokenKind == .keyword(.mutating) }) {
            context.diagnoseError(
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
            context.diagnoseError(
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
                context.diagnoseError(
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
                context.diagnoseError(
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
                context.diagnoseError(
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

        return mappings.map { kind, path, maxBodyBytes, _ in
            ScannedRoute(
                kind: kind,
                path: path,
                methodName: name,
                bodyTypeText: bodyTypeText,
                maxBodyBytesText: maxBodyBytes,
                isAsync: effects?.asyncSpecifier != nil,
                isThrows: effects?.throwsClause != nil,
                returnTypeText: returnType,
                node: function
            )
        }
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
    static func combinePaths(_ base: String, _ method: String) -> String {
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
    static func validatePath(
        _ path: String,
        name: String,
        at node: AttributeSyntax,
        in context: some MacroExpansionContext
    ) {
        guard path.hasPrefix("/") else {
            context.diagnoseError(
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
                    context.diagnoseError(
                        "route.path",
                        "@\(name) path '\(path)': '**' is only allowed as the final segment.",
                        at: node
                    )
                }
            } else if segment.hasPrefix(":") {
                let parameter = String(segment.dropFirst())
                if parameter.isEmpty {
                    context.diagnoseError(
                        "route.path",
                        "@\(name) path '\(path)' has a ':' segment with no parameter name.",
                        at: node
                    )
                } else if !seenParameters.insert(parameter).inserted {
                    context.diagnoseError(
                        "route.path",
                        "@\(name) path '\(path)' binds ':\(parameter)' more than once.",
                        at: node
                    )
                }
            }
        }
    }
}
