import SwiftSyntax
import SwiftSyntaxMacros

/// `@GetMapping`/`@PostMapping`/…/`@WebSocketMapping` (§4, §6.1). Pure
/// markers, one implementation for the whole family: all generated code
/// lives in `@Controller`'s expansion, which reads these attributes off the
/// methods. This macro's own expansion is empty; its job is validating the
/// attachment site so misuse fails at the method, not somewhere inside the
/// enclosing type's expansion.
public struct RouteMappingMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        let name = node.attributeName.as(IdentifierTypeSyntax.self)?.name.text ?? "RouteMapping"

        guard let function = declaration.as(FunctionDeclSyntax.self) else {
            context.diagnoseError(
                "mapping.notfunction",
                "@\(name) can only be attached to a controller method.",
                at: node
            )
            return []
        }

        // Validate the signature and the path pattern here, at the method —
        // scanRoutes and validatePath emit the diagnostics.
        let routes = RouteScanning.scanRoutes(of: function, in: context)
        for route in routes {
            validatePath(route.path, name: name, at: node, in: context)
        }
        return []
    }

    /// Pattern-syntax validation at compile time (§4: "path-pattern validity
    /// becomes information the build has before the binary exists"). Kept in
    /// lockstep with the runtime `RoutePattern` parser — these rules are the
    /// same ones it enforces.
    private static func validatePath(
        _ path: String,
        name: String,
        at node: AttributeSyntax,
        in context: some MacroExpansionContext
    ) {
        guard path.hasPrefix("/") else {
            context.diagnoseError(
                "mapping.path",
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
                        "mapping.path",
                        "@\(name) path '\(path)': '**' is only allowed as the final segment.",
                        at: node
                    )
                }
            } else if segment.hasPrefix(":") {
                let parameter = String(segment.dropFirst())
                if parameter.isEmpty {
                    context.diagnoseError(
                        "mapping.path",
                        "@\(name) path '\(path)' has a ':' segment with no parameter name.",
                        at: node
                    )
                } else if !seenParameters.insert(parameter).inserted {
                    context.diagnoseError(
                        "mapping.path",
                        "@\(name) path '\(path)' binds ':\(parameter)' more than once.",
                        at: node
                    )
                }
            }
        }
    }
}
