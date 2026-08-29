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

        // A mapping attribute on a method of a type that is not @Controller
        // compiles cleanly and registers nothing. Every line of generated
        // code lives in @Controller's expansion, which is what reads these
        // attributes off the members — so without it the route silently does
        // not exist, and the first anyone knows is a 404 that no diagnostic
        // ever hinted at.
        //
        // That is precisely the failure class GAPS.md's "@Scheduler shipped
        // inert, and every check passed" postmortem describes, still open in
        // this corner: no fixture covered it, because a fixture that produces
        // no output and no diagnostic looks like nothing to assert.
        //
        // An extension of a @Controller type counts as not-a-controller here,
        // and correctly so: @Controller reads its own member block, and a
        // mapping in an extension is just as inert.
        guard let enclosing = context.lexicalContext.first,
            hasControllerAttribute(enclosing)
        else {
            context.diagnoseError(
                "mapping.nocontroller",
                """
                @\(name) registers a route only on a method of a type annotated @Controller, \
                which is what reads these attributes. This method's enclosing type is not \
                annotated @Controller — nor is a method in an extension of one scanned — so \
                the route would silently never exist. Add @Controller to the type declaring \
                this method, or register the route with container.registerRoute.
                """,
                at: node
            )
            return []
        }

        // The validation itself belongs to @Controller, which scans the same
        // methods to build the routes. Doing it here as well emitted every
        // misuse diagnostic *twice*, at the identical line and column — the
        // fixtures pinned two, with a comment noting it, and the user still
        // saw double. Nothing is lost: `scanRoutes` reports at the method
        // either way.
        _ = function
        return []
    }

    /// Whether a lexical-context node is a type declaration carrying
    /// `@Controller`.
    private static func hasControllerAttribute(_ node: Syntax) -> Bool {
        guard let group = node.asProtocol(DeclGroupSyntax.self) else { return false }
        return group.attributes.contains { attribute in
            attribute.as(AttributeSyntax.self)?
                .attributeName.as(IdentifierTypeSyntax.self)?.name.text == "Controller"
        }
    }
}
