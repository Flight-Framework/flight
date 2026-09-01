import SwiftSyntax
import SwiftSyntaxMacros

/// `@Inject`. A pure marker: all generated code lives in
/// `@Component`'s expansion (which reads this attribute off the property).
/// Its own expansion is empty; its job is validating the attachment site at
/// the point of use so misuse fails on the property, not somewhere in the
/// enclosing type's expansion.
public struct InjectMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        validateInjectedProperty(node, declaration, name: "@Inject", in: context)
        return []
    }
}

/// `@ConfigValue`. Same marker pattern as `@Inject`; the key
/// argument is consumed by `@Component`'s expansion.
public struct ConfigValueMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        validateInjectedProperty(node, declaration, name: "@ConfigValue", in: context)
        return []
    }
}

/// Shared validation: must be a stored property (let or var — both are
/// assignable from the generated `init(_flight:)`) with an explicit type
/// annotation, since injection resolves by static type.
private func validateInjectedProperty(
    _ node: AttributeSyntax,
    _ declaration: some DeclSyntaxProtocol,
    name: String,
    in context: some MacroExpansionContext
) {
    guard let variable = declaration.as(VariableDeclSyntax.self) else {
        context.diagnoseError(
            "injected.notproperty",
            "\(name) can only be attached to a stored property.",
            at: node
        )
        return
    }
    guard let binding = variable.bindings.first else { return }
    if binding.typeAnnotation == nil {
        context.diagnoseError(
            "injected.untyped",
            "\(name) properties need an explicit type annotation — injection resolves by static type.",
            at: variable
        )
    }
    if binding.initializer != nil {
        context.diagnoseError(
            "injected.initialized",
            "\(name) properties must not have an initial value; the container supplies the value at construction.",
            at: variable
        )
    }
    if binding.accessorBlock != nil {
        context.diagnoseError(
            "injected.computed",
            "\(name) requires a stored property, not a computed one.",
            at: variable
        )
    }
}
