import FlightConfigCore
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

/// `@Settings("namespace")`. Expansion:
/// 1. `init(_flight:)` — one line per stored property, binding it against
///    `Configuration` under `namespace.<kebab-cased-property-name>`;
/// 2. `_flightRegister(_:)`, registering `Self` as a `.singleton`
///    `.settings`-stereotype component, calling `validate()` after
///    construction if the type declares one;
/// 3. conformance to `_FlightRegistrable`;
/// 4. if any property carries `@Secret`, a redacting `CustomStringConvertible`.
///
/// Deliberately self-contained rather than sharing `ComponentMacro`'s
/// property-collection machinery: the classification rules are different
/// enough (every plain property is an implicit config binding, not an error)
/// that sharing code would mean threading a mode flag through logic written
/// for a different shape. `RegistrableAttributesTests` is what keeps the two
/// registration thunks agreeing on what the build plugin needs to see.
///
/// The exact expansions are pinned by `Tests/Core/FlightCoreMacroTests/SettingsMacroFixtureTests`.
public struct SettingsMacro: MemberMacro, ExtensionMacro {

    // MARK: - MemberMacro

    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let namespace = settingsNamespace(node, in: context) else { return [] }
        guard validateAttachmentTarget(declaration, in: context) else { return [] }

        let fields = collectFields(from: declaration, namespace: namespace, in: context)
        let access = registrationAccess(for: declaration)

        var initLines: [String] = []
        for field in fields {
            if let defaultValue = field.defaultValue {
                // getIfPresent ?? default, not get(_:default:): a present but
                // malformed value must throw naming the key, never be
                // silently replaced by the default — same rule as
                // @ConfigValue, for the same reason.
                initLines.append(
                    "self.\(field.name) = try container.resolve(FlightCore.Configuration.self).getIfPresent(\(field.key), as: \(field.typeText).self) ?? (\(defaultValue))"
                )
            } else {
                initLines.append(
                    "self.\(field.name) = try container.resolve(FlightCore.Configuration.self).get(\(field.key), as: \(field.typeText).self)"
                )
            }
        }
        let initBody =
            initLines.isEmpty ? "" : "\n    " + initLines.joined(separator: "\n    ") + "\n"
        let resolvingInit: DeclSyntax = """
            internal init(_flight container: FlightCore.Container) throws {\(raw: initBody)}
            """

        let hasValidate = declaresInstanceValidate(declaration)
        // No manual leading spaces on the continuation lines: BasicFormat
        // re-indents raw text relative to its enclosing braces, and a
        // hand-added prefix here stacks on top of that rather than replacing
        // it.
        let constructAndValidate =
            hasValidate
            ? "let value = try Self(_flight: c)\ntry value.validate()\nreturn value"
            : "try Self(_flight: c)"
        let thunk: DeclSyntax = """
            \(raw: access)static func _flightRegister(_ container: FlightCore.Container) throws {
            container.register(Self.self, scope: .singleton, stereotype: .settings) { c in
            \(raw: constructAndValidate)
            }
            }
            """

        var members = [resolvingInit, thunk]
        if let redacted = redactingDescription(
            typeName: typeName(of: declaration), fields: fields, declaration: declaration)
        {
            members.append(redacted)
        }
        return members
    }

    // MARK: - ExtensionMacro

    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        var extensions: [DeclSyntax] = []
        for requested in protocols {
            // Matched by suffix, not exact text: real compilation and the
            // `assertMacroExpansion` test harness spell these differently
            // qualified (`FlightCore._FlightRegistrable` vs
            // `_FlightRegistrable`), and both are the same protocol.
            let name = requested.trimmedDescription
            switch true {
            case name.hasSuffix("_FlightRegistrable"):
                extensions.append(
                    """
                    extension \(type.trimmed): FlightCore._FlightRegistrable {}
                    """)
            case name.hasSuffix("CustomStringConvertible"):
                // The compiler only lists this when it is not already
                // satisfied elsewhere; `redactingDescription` (the member
                // role) is what actually decides whether a description was
                // generated. Both must agree the type has a @Secret field —
                // the member-role member and this conformance are two halves
                // of one feature, and either alone is useless: the property
                // with no conformance is never picked up by
                // `String(describing:)`; the conformance with no property is
                // a compile error.
                guard hasSecretField(declaration) else { continue }
                extensions.append(
                    """
                    extension \(type.trimmed): Swift.CustomStringConvertible {}
                    """)
            default:
                continue
            }
        }
        return extensions.compactMap { $0.as(ExtensionDeclSyntax.self) }
    }

    private static func hasSecretField(_ declaration: some DeclGroupSyntax) -> Bool {
        for member in declaration.memberBlock.members {
            guard let variable = member.decl.as(VariableDeclSyntax.self) else { continue }
            if variable.attributes.contains(where: {
                $0.as(AttributeSyntax.self)?.attributeName.as(IdentifierTypeSyntax.self)?.name.text
                    == "Secret"
            }) { return true }
        }
        return false
    }

    // MARK: - Field model

    private struct Field {
        let name: String
        let typeText: String
        let key: String
        /// Source text of the default expression, or nil for a required key.
        let defaultValue: String?
        let isSecret: Bool
    }

    private static func collectFields(
        from declaration: some DeclGroupSyntax,
        namespace: String,
        in context: some MacroExpansionContext
    ) -> [Field] {
        var fields: [Field] = []
        for member in declaration.memberBlock.members {
            guard let variable = member.decl.as(VariableDeclSyntax.self) else { continue }
            let isTypeLevel = variable.modifiers.contains {
                $0.name.tokenKind == .keyword(.static) || $0.name.tokenKind == .keyword(.class)
            }
            if isTypeLevel { continue }

            for binding in variable.bindings {
                // A computed property (has its own accessor block) is not
                // config-bound storage — an ordinary Swift convenience
                // computed from the bound fields is legitimate here.
                guard binding.accessorBlock == nil,
                    let pattern = binding.pattern.as(IdentifierPatternSyntax.self)
                else { continue }

                if hasAttribute(variable, named: "Autowired") {
                    context.diagnoseError(
                        "settings.autowired",
                        "@Autowired is not valid inside @Settings — settings hold configuration only. Put dependencies in a @Service or @Component instead.",
                        at: variable
                    )
                    continue
                }

                guard let typeAnnotation = binding.typeAnnotation else {
                    context.diagnoseError(
                        "settings.untyped",
                        "@Settings properties need an explicit type annotation — binding resolves by static type.",
                        at: variable
                    )
                    continue
                }
                let type = typeAnnotation.type
                if type.is(OptionalTypeSyntax.self)
                    || type.as(IdentifierTypeSyntax.self)?.name.text == "Optional"
                {
                    context.diagnoseError(
                        "settings.optional",
                        "'\(pattern.identifier.text)' may not be Optional. Give it a concrete default instead of allowing absence — @Settings binds a value once, at bootstrap, and a key that may or may not exist has no single answer for 'what did we configure'.",
                        at: variable
                    )
                    continue
                }

                let isLet = variable.bindingSpecifier.tokenKind == .keyword(.let)
                let ownInitializer = binding.initializer?.value.trimmedDescription
                if isLet, ownInitializer != nil {
                    context.diagnoseError(
                        "settings.letdefault",
                        "'\(pattern.identifier.text)' has a default value, so it must be 'var' — the generated initializer assigns it when configuration supplies a value, overriding the default.",
                        at: variable
                    )
                    continue
                }

                // Quoted source text, not a bare Swift value: this is spliced
                // directly into generated code, and an unquoted `auth.issuer`
                // parses as member access on an identifier named `auth`, not
                // as a string literal.
                var key =
                    "\"\(namespace).\(ConfigKeyNaming.kebabCase(pattern.identifier.text))\""
                var defaultValue = ownInitializer
                if let attribute = attribute(on: variable, named: "ConfigValue") {
                    guard let explicitKey = firstArgumentSource(of: attribute) else {
                        context.diagnoseError(
                            "settings.dynamickey",
                            "@ConfigValue inside @Settings needs a string-literal key, e.g. @ConfigValue(\"legacy.key\").",
                            at: attribute
                        )
                        continue
                    }
                    key = explicitKey
                    if let explicitDefault = labeledArgumentSource(of: attribute, label: "default")
                    {
                        defaultValue = explicitDefault
                    }
                }

                fields.append(
                    Field(
                        name: pattern.identifier.text,
                        typeText: type.trimmedDescription,
                        key: key,
                        defaultValue: defaultValue,
                        isSecret: hasAttribute(variable, named: "Secret")
                    ))
            }
        }
        return fields
    }

    /// Whether the type declares an instance method literally named
    /// `validate` with no parameters — best-effort syntactic detection.
    /// A mismatched signature (throwing vs not, a stray parameter) surfaces
    /// as an ordinary compiler error at the generated call site rather than
    /// here; that is the same tradeoff every macro in this file makes for
    /// method-shape assumptions it cannot fully type-check.
    private static func declaresInstanceValidate(_ declaration: some DeclGroupSyntax) -> Bool {
        for member in declaration.memberBlock.members {
            guard let function = member.decl.as(FunctionDeclSyntax.self),
                function.name.text == "validate",
                function.signature.parameterClause.parameters.isEmpty
            else { continue }
            let isStatic = function.modifiers.contains {
                $0.name.tokenKind == .keyword(.static) || $0.name.tokenKind == .keyword(.class)
            }
            if !isStatic { return true }
        }
        return false
    }

    /// A `description` that redacts `@Secret` fields, generated only when at
    /// least one field needs it and the type has not already declared its
    /// own `description` — this is additive, not an override.
    private static func redactingDescription(
        typeName: String, fields: [Field], declaration: some DeclGroupSyntax
    ) -> DeclSyntax? {
        guard fields.contains(where: \.isSecret) else { return nil }
        let alreadyDeclaresDescription = declaration.memberBlock.members.contains {
            if let function = $0.decl.as(FunctionDeclSyntax.self) { return function.name.text == "description" }
            if let variable = $0.decl.as(VariableDeclSyntax.self) {
                return variable.bindings.contains {
                    $0.pattern.as(IdentifierPatternSyntax.self)?.identifier.text == "description"
                }
            }
            return false
        }
        guard !alreadyDeclaresDescription else { return nil }

        let parts = fields.map { field in
            // `body` is spliced as raw source text inside a Swift string
            // literal (the generated `description`'s own `"..."`), so a
            // secret field's quotes must reach the GENERATED source already
            // escaped — \\\" here is one backslash character followed by one
            // quote character, twice, around REDACTED.
            field.isSecret
                ? "\(field.name): \\\"<REDACTED>\\\""
                : "\(field.name): \\(String(reflecting: self.\(field.name)))"
        }
        let body = "\(typeName)(" + parts.joined(separator: ", ") + ")"
        return """
            public var description: String { "\(raw: body)" }
            """
    }

    // MARK: - Attribute helpers

    private static func hasAttribute(_ variable: VariableDeclSyntax, named name: String) -> Bool {
        attribute(on: variable, named: name) != nil
    }

    private static func attribute(
        on variable: VariableDeclSyntax, named name: String
    ) -> AttributeSyntax? {
        for attribute in variable.attributes {
            if let attr = attribute.as(AttributeSyntax.self),
                attr.attributeName.as(IdentifierTypeSyntax.self)?.name.text == name
            {
                return attr
            }
        }
        return nil
    }

    private static func firstArgumentSource(of attribute: AttributeSyntax) -> String? {
        guard let arguments = attribute.arguments?.as(LabeledExprListSyntax.self),
            let first = arguments.first, first.label == nil
        else { return nil }
        let text = first.expression.trimmedDescription
        return text == "nil" ? nil : text
    }

    private static func labeledArgumentSource(of attribute: AttributeSyntax, label: String)
        -> String?
    {
        guard let arguments = attribute.arguments?.as(LabeledExprListSyntax.self) else {
            return nil
        }
        for argument in arguments where argument.label?.text == label {
            return argument.expression.trimmedDescription
        }
        return nil
    }

    /// The namespace argument: `@Settings("auth")`'s single unlabeled string
    /// literal. A non-literal expression can't feed the compile-time
    /// flight.yaml check the build plugin runs for required keys, so it is
    /// rejected here rather than accepted and silently unchecked.
    private static func settingsNamespace(
        _ node: AttributeSyntax, in context: some MacroExpansionContext
    ) -> String? {
        guard let arguments = node.arguments?.as(LabeledExprListSyntax.self),
            let first = arguments.first, first.label == nil,
            let literal = first.expression.as(StringLiteralExprSyntax.self),
            literal.segments.count == 1,
            case .stringSegment(let segment)? = literal.segments.first
        else {
            context.diagnoseError(
                "settings.nonamespace",
                "@Settings requires a namespace, as a string literal, e.g. @Settings(\"auth\").",
                at: node
            )
            return nil
        }
        return segment.content.text
    }

    // camelCase -> kebab-case lives in FlightConfigCore's ConfigKeyNaming —
    // shared with flight-registration-gen, which needs the identical
    // derivation for its build-time flight.yaml check. One implementation,
    // not two kept in sync by a test.

    // MARK: - Validation

    /// Final class or struct only — same rule and same rationale as
    /// `@Component`.
    private static func validateAttachmentTarget(
        _ declaration: some DeclGroupSyntax, in context: some MacroExpansionContext
    ) -> Bool {
        if let classDecl = declaration.as(ClassDeclSyntax.self) {
            let isFinal = classDecl.modifiers.contains { $0.name.tokenKind == .keyword(.final) }
            if !isFinal {
                context.diagnoseError(
                    "settings.nonfinal",
                    "@Settings requires a final class (or a struct). Mark '\(classDecl.name.text)' final.",
                    at: classDecl.name
                )
                return false
            }
            return true
        }
        if declaration.is(StructDeclSyntax.self) { return true }
        // Anything else — an enum, an actor, a protocol — returned false with
        // no diagnostic at all, so the author's first sign of trouble was an
        // opaque `_FlightRegistrable` conformance error from the extension
        // role, pointing at a line they did not write.
        let kind: String
        switch declaration.kind {
        case .enumDecl: kind = "an enum"
        case .actorDecl: kind = "an actor"
        case .protocolDecl: kind = "a protocol"
        case .extensionDecl: kind = "an extension"
        default: kind = "this declaration"
        }
        context.diagnoseError(
            "settings.unsupported",
            """
            @Settings can only be attached to a struct or a final class; \(kind) has no \
            memberwise initializer for it to generate against.
            """,
            at: declaration
        )
        return false
    }

    private static func typeName(of declaration: some DeclGroupSyntax) -> String {
        if let structDecl = declaration.as(StructDeclSyntax.self) { return structDecl.name.text }
        if let classDecl = declaration.as(ClassDeclSyntax.self) { return classDecl.name.text }
        return "Settings"
    }

    private static func registrationAccess(for declaration: some DeclGroupSyntax) -> String {
        let modifiers: DeclModifierListSyntax
        if let classDecl = declaration.as(ClassDeclSyntax.self) {
            modifiers = classDecl.modifiers
        } else if let structDecl = declaration.as(StructDeclSyntax.self) {
            modifiers = structDecl.modifiers
        } else {
            return ""
        }
        for modifier in modifiers {
            switch modifier.name.tokenKind {
            case .keyword(.public), .keyword(.package):
                return "\(modifier.name.text) "
            default:
                continue
            }
        }
        return ""
    }
}
