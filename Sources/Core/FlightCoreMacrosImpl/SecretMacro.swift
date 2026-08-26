import SwiftSyntax
import SwiftSyntaxMacros

/// `@Secret`. A pure marker, exactly like `@Autowired`: the redaction it
/// enables lives in `@Settings`'s expansion, which reads this attribute off
/// each property.
///
/// Deliberately its own file, separate from `SettingsMacro.swift`:
/// `RegistrableAttributesTests` finds every macro-implementing type in a file
/// that mentions the generated registration thunk's name by searching file
/// text, and expects the generator's `registrableAttributes` to list it.
/// `@Secret` never emits that thunk — sharing a file with `@Settings` (which
/// does) made the test see both names in one place and expect both
/// registered, which is wrong for a marker that isn't a stereotype at all.
/// (Spelling the thunk's name here, even in this explanation, would trip the
/// same text search — which is itself evidence for why the split is worth
/// making rather than special-casing the test.)
public struct SecretMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard declaration.is(VariableDeclSyntax.self) else {
            context.diagnoseError(
                "secret.notproperty",
                "@Secret can only be attached to a stored property.",
                at: node
            )
            return []
        }
        return []
    }
}
