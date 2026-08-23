import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// The shared expansion behind `@Component` and its stereotypes. Each conforming macro generates:
/// - `init(_flight:)` — constructs the type with every `@Autowired` property
/// container-resolved and every `@ConfigValue` property config-resolved;
/// - `_flightRegister(_:)` — the registration thunk the build plugin's
/// generated `_registerAll` calls;
/// - `extension T: _FlightRegistrable {}`.
///
/// Stereotypes expand *identically* to `@Component` — the only difference is
/// the `stereotype:` argument on the generated register call.
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

struct InjectedProperty {
    enum Kind {
        case autowired(qualifier: String?)
        /// `defaultValue` is the `default:` argument's source text,
        /// re-embedded verbatim in the expansion (nil = required key).
        case configValue(key: String, defaultValue: String?)
    }
    let name: String
    let typeText: String
    let kind: Kind
    let node: VariableDeclSyntax
}

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

        // 1. Resolving initializer. Internal always: its only caller is the
        // thunk below, which lives on the same type.
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
                    // getIfPresent ?? default rather than get(_:default:):
                    // a present-but-malformed value must throw (failing the
                    // module's configure with the key named), never be
                    // silently replaced by the default. Parenthesized so
                    // low-precedence default expressions (ternaries) can't
                    // rebind against `??`.
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
        let initBody = initLines.isEmpty ? "" : "\n " + initLines.joined(separator: "\n ") + "\n"
        let resolvingInit: DeclSyntax = """
            internal init(_flight container: FlightCore.Container) throws {\(raw: initBody)}
            """

        // 2. Registration thunk. Stereotypes differ from @Component only in
        // the trailing stereotype: argument.
        let stereotypeSuffix = stereotypeArgument.map { ", stereotype: \($0)" } ?? ""
        let registerCall: String
        if let qualifierExpr {
            registerCall =
                "container.register(Self.self, qualifier: \(qualifierExpr), scope: \(scopeExpr)\(stereotypeSuffix))"
        } else {
            registerCall = "container.register(Self.self, scope: \(scopeExpr)\(stereotypeSuffix))"
        }
        let thunk: DeclSyntax = """
            \(raw: access)static func _flightRegister(_ container: FlightCore.Container) throws {
            \(raw: registerCall) { c in
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
        // The compiler passes only the conformances still missing; if the
        // type already declares _FlightRegistrable, this list is empty.
        guard !protocols.isEmpty else { return [] }
        let ext: DeclSyntax = """
            extension \(type.trimmed): FlightCore._FlightRegistrable {}
            """
        guard let extensionDecl = ext.as(ExtensionDeclSyntax.self) else { return [] }
        return [extensionDecl]
    }

    // MARK: - Validation

    /// Final class or struct only. Non-final classes would need a `required`
    /// resolving init to make `Self(_flight:)` legal in a static context —
    /// deliberately unsupported in v1 rather than silently generating
    /// subclass-hostile code. Actors are deferred: container-managed actors
    /// are a Flight-wide design question, not
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

    /// the fixture 6 decision: two `@Autowired` properties of the same type
    /// are a compile error unless each carries a distinct explicit qualifier.
    private static func validateQualifierDisambiguation(
        _ properties: [InjectedProperty],
        in context: some MacroExpansionContext
    ) -> Bool {
        var seen: [String: String?] = [:]  // typeText → first qualifier
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

    /// M-3 : the generated `init(_flight:)` assigns only
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
                    "Stored property '\(pattern.identifier.text)' of a \(displayName) type needs a default value — the generated init(_flight:) assigns only @Autowired/@ConfigValue properties.",
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
            guard let binding = variable.bindings.first,
                let pattern = binding.pattern.as(IdentifierPatternSyntax.self)
            else { continue }
            guard let typeAnnotation = binding.typeAnnotation else {
                context.diagnoseError(
                    "injected.untyped",
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

    /// `_flightRegister` must be callable from the generated cross-module
    /// `_registerAll`, and must satisfy the public `_FlightRegistrable`
    /// requirement — so it mirrors the type's own access level.
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
