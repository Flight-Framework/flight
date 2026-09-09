import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import FlightMacroSupport
import SwiftSyntaxMacros

/// The shared expansion behind `@Component` and its stereotypes: a
/// parameterized initializer taking every `@Inject` property as a parameter
/// and reading every `@ConfigValue` property from `Configuration`. The
/// composition root calls it, wiring the injected values by type. The
/// container-era `init(_flight:)`, `_flightRegister` thunk, and
/// `_FlightRegistrable` conformance are gone with the container.
///
/// Stereotypes expand *identically* to `@Component`; the stereotype only
/// tags the build-scanned descriptor (for Actuator), not the expansion.
///
/// The authoritative expansions are the fixtures in FlightCoreMacroTests
///.
public protocol RegistrationMacro: MemberMacro, ExtensionMacro {
    /// Source text of the `stereotype:` argument in the generated register
    /// call, or nil to omit it (`@Component` — the parameter defaults to
    /// `.component`, keeping the base expansion unchanged).
    static var stereotypeArgument: String? { get }
    /// The attribute's user-facing spelling, for diagnostics.
    static var displayName: String { get }
}

/// `@Component` — the base registration macro; no stereotype tag.
public struct ComponentMacro: RegistrationMacro {
    public static let stereotypeArgument: String? = nil
    public static let displayName = "@Component"
}

/// `@Service` — business logic, third-party clients.
public struct ServiceMacro: RegistrationMacro {
    public static let stereotypeArgument: String? = ".service"
    public static let displayName = "@Service"
}

/// `@Repository` — data access.
public struct RepositoryMacro: RegistrationMacro {
    public static let stereotypeArgument: String? = ".repository"
    public static let displayName = "@Repository"
}

// MARK: - Injected-property model
// (File scope — nested types are not permitted in protocol extensions.)

extension RegistrationMacro {

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

        let (scopeExpr, qualifierExpr) = parseComponentArguments(node)
        let access = registrationAccess(for: declaration)

        // Constructor injection: a component is built by the composition
        // root through this initializer. The container-era init(_flight:) and
        // _flightRegister thunk are gone with the container.
        let parameterInit = parameterizedInitializer(
            properties: properties, access: access, declaration: declaration)
        _ = (scopeExpr, qualifierExpr, stereotypeArgument)  // no longer emitted
        return [parameterInit].compactMap { $0 }
    }

    // MARK: - ExtensionMacro

    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        // No conformance to emit: the container marker protocol is gone.
        []
    }

    // MARK: - Validation

    /// Final class or struct only. Non-final classes would need a `required`
    /// initializer to make the generated `Self(...)` legal in a static
    /// context — deliberately unsupported in v1 rather than silently
    /// generating subclass-hostile code. Actors are deferred: actor-based
    /// components are a Flight-wide design question, not
    /// a macro detail to improvise.
    private static func validateAttachmentTarget(
        _ declaration: some DeclGroupSyntax,
        in context: some MacroExpansionContext
    ) -> Bool {
        if let classDecl = declaration.as(ClassDeclSyntax.self) {
            let isFinal = classDecl.modifiers.contains { $0.name.tokenKind == .keyword(.final) }
            if !isFinal {
                context.diagnoseError(
                    "component.nonfinal",
                    "\(displayName) requires a final class (or a struct). Mark '\(classDecl.name.text)' final.",
                    at: classDecl.name
                )
                return false
            }
            return true
        }
        if declaration.is(StructDeclSyntax.self) { return true }
        context.diagnoseError(
            "component.unsupported",
            "\(displayName) can only be attached to a final class or a struct.",
            at: declaration
        )
        return false
    }

    /// the fixture 6 decision: two `@Inject` properties of the same type
    /// are a compile error unless each carries a distinct explicit qualifier.
    private static func validateQualifierDisambiguation(
        _ properties: [InjectedProperty],
        in context: some MacroExpansionContext
    ) -> Bool {
        // Two properties collide when they would resolve the *same key* —
        // same type and same qualifier, "no qualifier" being a key of its
        // own. It used to be enough for the types to match with either
        // qualifier absent, which refused the shape the stack's own
        // datasource convention produces:
        //
        //     @Inject var pool: PostgresDataSource                    // primary
        //     @Inject("analytics") var analytics: PostgresDataSource
        //
        // flight-data registers the primary pool unqualified *as well as* by
        // name, precisely so the one-database case needs no qualifier. Those
        // two properties name two different registrations, and refusing them
        // made the documented convention unusable inside one type.
        var seenPairs: Set<String> = []
        var valid = true
        for property in properties {
            guard case .inject(let qualifier) = property.kind else { continue }
            let pairKey = "\(property.typeText)|\(qualifier ?? "<nil>")"
            if !seenPairs.insert(pairKey).inserted {
                context.diagnoseError(
                    "inject.ambiguous",
                    "Two @Inject properties of type '\(property.typeText)' require distinct explicit qualifiers, e.g. @Inject(\"primary\").",
                    at: property.node
                )
                valid = false
            }
        }
        return valid
    }

    /// M-3 : the generated initializer assigns only
    /// injected properties, so any other stored property must carry a default
    /// value (or be an implicitly-nil optional `var`). Without this check the
    /// failure is a "return from initializer without initializing all stored
    /// properties" error pointing *inside the macro expansion* — this
    /// diagnostic names the actual fix at the actual property instead.
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
                // An optional `var` is implicitly nil-initialized.
                if isVar, let type = binding.typeAnnotation?.type,
                    type.is(OptionalTypeSyntax.self)
                        || type.as(IdentifierTypeSyntax.self)?.name.text == "Optional"
                {
                    continue
                }
                context.diagnoseError(
                    "component.uninitialized",
                    "Stored property '\(pattern.identifier.text)' of a \(displayName) type needs a default value — the generated initializer assigns only @Inject/@ConfigValue properties.",
                    at: variable
                )
                valid = false
            }
        }
        return valid
    }

    // MARK: - Collection

    private static func collectInjectedProperties(
        from declaration: some DeclGroupSyntax,
        in context: some MacroExpansionContext
    ) throws -> [InjectedProperty] {
        var properties: [InjectedProperty] = []
        for member in declaration.memberBlock.members {
            guard let variable = member.decl.as(VariableDeclSyntax.self) else { continue }
            guard let kind = injectionKind(of: variable, in: context) else { continue }
            // A type-level property was collected like any other, and the
            // generated initializer then assigned to a static member —
            // a compile error inside an expansion the author cannot see,
            // instead of a diagnostic naming the problem.
            if variable.modifiers.contains(where: {
                $0.name.tokenKind == .keyword(.static) || $0.name.tokenKind == .keyword(.class)
            }) {
                context.diagnoseError(
                    "injected.static",
                    """
                    Injection is per-instance: the container populates properties in the \
                    generated initializer, and a static property has no instance to belong \
                    to. Make it an instance property, or resolve it explicitly where it is \
                    used.
                    """,
                    at: variable
                )
                continue
            }
            guard let binding = variable.bindings.first,
                let pattern = binding.pattern.as(IdentifierPatternSyntax.self)
            else { continue }
            guard let typeAnnotation = binding.typeAnnotation else {
                context.diagnoseError(
                    "injected.untyped",
                    "@Inject/@ConfigValue properties need an explicit type annotation — injection resolves by static type.",
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
            case "Inject":
                return .inject(qualifier: firstArgumentSource(of: attr))
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

    /// Source text of the first unlabeled argument (a string literal in the
    /// supported grammar), or nil. Kept as source text — the generated code
    /// re-embeds it verbatim, so escapes survive untouched.
    private static func firstArgumentSource(of attribute: AttributeSyntax) -> String? {
        guard let arguments = attribute.arguments?.as(LabeledExprListSyntax.self),
            let first = arguments.first, first.label == nil
        else { return nil }
        let text = first.expression.trimmedDescription
        return text == "nil" ? nil : text
    }

    /// Source text of a labeled argument (e.g. `default:` on @ConfigValue),
    /// or nil. Same verbatim re-embedding rationale as above.
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

    // MARK: - @Component arguments

    /// Returns (scope expression source, qualifier expression source?).
    private static func parseComponentArguments(_ node: AttributeSyntax) -> (String, String?) {
        var scope = ".singleton"
        var qualifier: String? = nil
        if let arguments = node.arguments?.as(LabeledExprListSyntax.self) {
            for argument in arguments {
                switch argument.label?.text {
                case "scope":
                    scope = argument.expression.trimmedDescription
                case "qualifier":
                    let text = argument.expression.trimmedDescription
                    qualifier = text == "nil" ? nil : text
                default:
                    break
                }
            }
        }
        return (scope, qualifier)
    }

    /// The generated initializer must be callable from the generated
    /// cross-module composition root — so it mirrors the type's own access
    /// level.
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
