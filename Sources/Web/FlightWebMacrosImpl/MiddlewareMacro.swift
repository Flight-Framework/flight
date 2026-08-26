import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

/// `@Middleware`. Expands like Flight Core's `@Component` — resolving
/// `init(_flight:)`, registration thunk, `_FlightRegistrable` conformance —
/// with two differences: the registration is always `.singleton` (a
/// middleware type is resolved once, when a `container.pipeline { }` first
/// assembles the chain — a `.scoped` instance resolved there would be
/// permanently pinned to whichever request triggered that first
/// resolution), and the generated extension also declares conformance to
/// `FlightWeb.Middleware`, so the type's own `handle(_:next:)` is all it
/// needs to write.
///
/// Self-contained rather than sharing Flight Core's `RegistrationMacro`
/// (the shared expansion behind `@Component`/`@Service`/`@Repository`):
/// `FlightWebMacrosImpl` does not depend on `FlightCoreMacrosImpl`, the same
/// reason `@Controller` in this same file's sibling `ControllerMacro.swift`
/// duplicates rather than shares that logic. This mirrors `ComponentMacro`'s
/// property model, not `ControllerMacro`'s — no route metadata here.
///
/// The exact expansion is pinned by Tests/Web/FlightWebMacroTests.
public struct MiddlewareMacro: MemberMacro, ExtensionMacro {

    // MARK: - MemberMacro

    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard validateAttachmentTarget(declaration, in: context) else { return [] }

        let properties = try collectInjectedProperties(from: declaration, in: context)
        guard validateQualifierDisambiguation(properties, in: context) else { return [] }
        guard validateNonInjectedStorage(declaration, injected: properties, in: context) else {
            return []
        }
        let access = registrationAccess(for: declaration)

        var initLines: [String] = []
        for property in properties {
            switch property.kind {
            case .autowired(let qualifier):
                if let qualifier {
                    initLines.append(
                        "self.\(property.name) = try container.resolve(\(property.typeText).self, qualifier: \(qualifier))"
                    )
                } else {
                    initLines.append(
                        "self.\(property.name) = try container.resolve(\(property.typeText).self)"
                    )
                }
            case .configValue(let key, let defaultValue):
                if let defaultValue {
                    initLines.append(
                        "self.\(property.name) = try container.resolve(FlightCore.Configuration.self).getIfPresent(\(key), as: \(property.typeText).self) ?? (\(defaultValue))"
                    )
                } else {
                    initLines.append(
                        "self.\(property.name) = try container.resolve(FlightCore.Configuration.self).get(\(key), as: \(property.typeText).self)"
                    )
                }
            }
        }
        let initBody =
            initLines.isEmpty ? "" : "\n    " + initLines.joined(separator: "\n    ") + "\n"
        let resolvingInit: DeclSyntax = """
            internal init(_flight container: FlightCore.Container) throws {\(raw: initBody)}
            """

        let thunk: DeclSyntax = """
            \(raw: access)static func _flightRegister(_ container: FlightCore.Container) throws {
            container.register(Self.self, scope: .singleton, stereotype: .middleware) { c in
            try Self(_flight: c)
            }
            }
            """

        return [resolvingInit, thunk]
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
            let name = requested.trimmedDescription
            switch true {
            case name.hasSuffix("_FlightRegistrable"):
                extensions.append(
                    """
                    extension \(type.trimmed): FlightCore._FlightRegistrable {}
                    """)
            case name.hasSuffix("Middleware"):
                extensions.append(
                    """
                    extension \(type.trimmed): FlightWeb.Middleware {}
                    """)
            default:
                continue
            }
        }
        return extensions.compactMap { $0.as(ExtensionDeclSyntax.self) }
    }

    // MARK: - Injected-property model (mirrors ComponentMacro)

    private struct InjectedProperty {
        enum Kind {
            case autowired(qualifier: String?)
            case configValue(key: String, defaultValue: String?)
        }
        let name: String
        let typeText: String
        let kind: Kind
        let node: VariableDeclSyntax
    }

    private static func collectInjectedProperties(
        from declaration: some DeclGroupSyntax,
        in context: some MacroExpansionContext
    ) throws -> [InjectedProperty] {
        var properties: [InjectedProperty] = []
        for member in declaration.memberBlock.members {
            guard let variable = member.decl.as(VariableDeclSyntax.self) else { continue }
            guard let kind = injectionKind(of: variable, in: context) else { continue }
            guard let binding = variable.bindings.first,
                let pattern = binding.pattern.as(IdentifierPatternSyntax.self)
            else { continue }
            guard let typeAnnotation = binding.typeAnnotation else {
                context.diagnoseError(
                    "middleware.untyped",
                    "@Autowired/@ConfigValue properties need an explicit type annotation — injection resolves by static type.",
                    at: variable
                )
                continue
            }
            properties.append(
                InjectedProperty(
                    name: pattern.identifier.text,
                    typeText: typeAnnotation.type.trimmedDescription,
                    kind: kind,
                    node: variable
                )
            )
        }
        return properties
    }

    private static func injectionKind(
        of variable: VariableDeclSyntax,
        in context: some MacroExpansionContext
    ) -> InjectedProperty.Kind? {
        for attribute in variable.attributes {
            guard let attr = attribute.as(AttributeSyntax.self),
                let name = attr.attributeName.as(IdentifierTypeSyntax.self)?.name.text
            else { continue }
            switch name {
            case "Autowired":
                return .autowired(qualifier: firstArgumentSource(of: attr))
            case "ConfigValue":
                guard let key = firstArgumentSource(of: attr) else {
                    context.diagnoseError(
                        "configvalue.nokey",
                        "@ConfigValue requires a key, e.g. @ConfigValue(\"server.port\").",
                        at: attr
                    )
                    return nil
                }
                return .configValue(
                    key: key, defaultValue: labeledArgumentSource(of: attr, label: "default"))
            default:
                continue
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

    // MARK: - Validation (mirrors ComponentMacro)

    private static func validateAttachmentTarget(
        _ declaration: some DeclGroupSyntax,
        in context: some MacroExpansionContext
    ) -> Bool {
        if let classDecl = declaration.as(ClassDeclSyntax.self) {
            let isFinal = classDecl.modifiers.contains { $0.name.tokenKind == .keyword(.final) }
            if !isFinal {
                context.diagnoseError(
                    "middleware.nonfinal",
                    "@Middleware requires a final class (or a struct). Mark '\(classDecl.name.text)' final.",
                    at: classDecl.name
                )
                return false
            }
            return true
        }
        if declaration.is(StructDeclSyntax.self) { return true }
        context.diagnoseError(
            "middleware.unsupported",
            "@Middleware can only be attached to a final class or a struct.",
            at: declaration
        )
        return false
    }

    private static func validateQualifierDisambiguation(
        _ properties: [InjectedProperty],
        in context: some MacroExpansionContext
    ) -> Bool {
        var seen: [String: String?] = [:]
        var seenPairs: Set<String> = []
        var valid = true
        for property in properties {
            guard case .autowired(let qualifier) = property.kind else { continue }
            let pairKey = "\(property.typeText)|\(qualifier ?? "<nil>")"
            if let first = seen[property.typeText] {
                if qualifier == nil || first == nil || seenPairs.contains(pairKey) {
                    context.diagnoseError(
                        "autowired.ambiguous",
                        "Two @Autowired properties of type '\(property.typeText)' require distinct explicit qualifiers, e.g. @Autowired(\"primary\").",
                        at: property.node
                    )
                    valid = false
                }
            }
            seen[property.typeText] = seen[property.typeText] ?? qualifier
            seenPairs.insert(pairKey)
        }
        return valid
    }

    private static func validateNonInjectedStorage(
        _ declaration: some DeclGroupSyntax,
        injected: [InjectedProperty],
        in context: some MacroExpansionContext
    ) -> Bool {
        let injectedNames = Set(injected.map(\.name))
        var valid = true
        for member in declaration.memberBlock.members {
            guard let variable = member.decl.as(VariableDeclSyntax.self) else { continue }
            let isTypeLevel = variable.modifiers.contains {
                $0.name.tokenKind == .keyword(.static) || $0.name.tokenKind == .keyword(.class)
            }
            if isTypeLevel { continue }
            let isVar = variable.bindingSpecifier.tokenKind == .keyword(.var)
            for binding in variable.bindings {
                guard binding.accessorBlock == nil,
                    binding.initializer == nil,
                    let pattern = binding.pattern.as(IdentifierPatternSyntax.self),
                    !injectedNames.contains(pattern.identifier.text)
                else { continue }
                if isVar, let type = binding.typeAnnotation?.type,
                    type.is(OptionalTypeSyntax.self)
                        || type.as(IdentifierTypeSyntax.self)?.name.text == "Optional"
                {
                    continue
                }
                context.diagnoseError(
                    "middleware.uninitialized",
                    "Stored property '\(pattern.identifier.text)' of a @Middleware type needs a default value — the generated init(_flight:) assigns only @Autowired/@ConfigValue properties.",
                    at: variable
                )
                valid = false
            }
        }
        return valid
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
