import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// `@Controller` (§4). Expands exactly like Flight Core's `@Component` —
/// resolving `init(_flight:)`, registration thunk, `_FlightRegistrable`
/// conformance — with one purely additive difference: `_flightRegister(_:)`
/// also registers one `RouteRegistration` component per mapped method, carrying
/// (HTTP method, path pattern, encoded handler thunk) into the same
/// container every other component goes through. Routing is not a distinct
/// system from dependency injection.
///
/// `@Controller`'s own optional path argument is a base path, combined with
/// every mapped method's path (Spring's class+method `@RequestMapping`
/// combination rule — see `RouteScanning.combinePaths`); the combination is
/// resolved to a single literal at macro-expansion time, so it costs nothing
/// at runtime and duplicate-route detection runs on the already-combined
/// paths.
///
/// The injection half (`@Autowired`/`@ConfigValue` handling, attachment and
/// storage validation) deliberately mirrors ComponentMacro line for line —
/// same diagnostics, same generated shapes — so a controller author's mental
/// model transfers from components unchanged. The authoritative expansions
/// are the fixtures in FlightWebMacroTests.
public struct ControllerMacro: MemberMacro, ExtensionMacro {

    // MARK: - Injected-property model (mirrors ComponentMacro)

    struct InjectedProperty {
        enum Kind {
            case autowired(qualifier: String?)
            case configValue(key: String, defaultValue: String?)
        }
        let name: String
        let typeText: String
        let kind: Kind
        let node: VariableDeclSyntax
    }

    // MARK: - MemberMacro

    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let typeName = validateAttachmentTarget(declaration, in: context) else { return [] }

        let properties = collectInjectedProperties(from: declaration, in: context)
        guard validateQualifierDisambiguation(properties, in: context) else { return [] }
        guard validateNonInjectedStorage(declaration, injected: properties, in: context) else { return [] }

        let basePath = parseBasePath(node, in: context)
        let routes = collectRoutes(from: declaration, in: context)
        let combinedRoutes = routes.map { route in
            (route: route, path: RouteScanning.combinePaths(basePath, route.path))
        }
        guard validateNoDuplicateRoutes(combinedRoutes, in: context) else { return [] }

        let access = registrationAccess(for: declaration)

        // 1. Resolving initializer — identical shape to @Component's.
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
        let initBody = initLines.isEmpty ? "" : "\n    " + initLines.joined(separator: "\n    ") + "\n"
        let resolvingInit: DeclSyntax = """
        internal init(_flight container: FlightCore.Container) throws {\(raw: initBody)}
        """

        // 2. Registration thunk: the controller component, then its routes —
        //    ordered so eager route construction at freeze() can resolve the
        //    controller mid-freeze (Flight Core §2.1).
        var thunkLines: [String] = [
            "container.register(Self.self, scope: .singleton) { c in",
            "    try Self(_flight: c)",
            "}",
        ]
        for (route, path) in combinedRoutes {
            thunkLines.append(contentsOf: routeRegistrationLines(for: route, path: path, controller: typeName, pipelines: parsePipelines(node)))
        }
        let thunkBody = thunkLines.map { "    \($0)" }.joined(separator: "\n")
        let thunk: DeclSyntax = """
        \(raw: access)static func _flightRegister(_ container: FlightCore.Container) throws {
        \(raw: thunkBody)
        }
        """

        return [resolvingInit, thunk]
    }

    /// The generated registration for one route. The qualifier embeds the
    /// runtime-qualified controller name so two controllers may declare
    /// colliding patterns without tripping Core's duplicate-registration
    /// precondition — the Router reports the conflict as a proper startup
    /// error naming both sources instead.
    private static func routeRegistrationLines(for route: ScannedRoute, path: String, controller: String, pipelines: String?) -> [String] {
        let kind = route.kind.isUpgrade ? ".upgrade(.webSocket)" : ".http"

        var call = "controller.\(route.methodName)(context"
        if route.bodyTypeText != nil { call += ", body: body" }
        call += ")"
        if route.isAsync { call = "await \(call)" }
        if route.isThrows { call = "try \(call)" }

        var handlerLines: [String] = []
        if let bodyType = route.bodyTypeText {
            handlerLines.append("let body = try FlightWeb.decodeRequestBody(\(bodyType).self, from: context)")
        }
        if route.kind.isUpgrade {
            handlerLines.append("let upgradeHandler = \(call)")
            handlerLines.append("return FlightWeb.Response.upgrade(handler: upgradeHandler, context: context)")
        } else if route.returnTypeText != nil {
            handlerLines.append("let result = \(call)")
            handlerLines.append("return try FlightWeb.encodeResponse(result, for: context)")
        } else {
            handlerLines.append("\(call)")
            handlerLines.append("return FlightWeb.Response.noContent")
        }

        var lines: [String] = []
        lines.append("container.register(FlightWeb.RouteRegistration.self, qualifier: \"\(route.kind.httpMethod) \(path) @\" + String(reflecting: Self.self) + \".\(route.methodName)\", scope: .singleton) { c in")
        lines.append("    let controller = try c.resolve(Self.self)")
        let pipelinesClause = pipelines.map { ", pipelines: \($0)" } ?? ""
    lines.append("    return FlightWeb.RouteRegistration(method: \"\(route.kind.httpMethod)\", path: \"\(path)\", kind: \(kind), source: String(reflecting: Self.self) + \".\(route.methodName)\"\(pipelinesClause)) { context in")
        for line in handlerLines {
            lines.append("        \(line)")
        }
        lines.append("    }")
        lines.append("}")
        return lines
    }

    // MARK: - ExtensionMacro

    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        guard !protocols.isEmpty else { return [] }
        let ext: DeclSyntax = """
        extension \(type.trimmed): FlightCore._FlightRegistrable {}
        """
        guard let extensionDecl = ext.as(ExtensionDeclSyntax.self) else { return [] }
        return [extensionDecl]
    }

    // MARK: - Route collection

    private static func collectRoutes(
        from declaration: some DeclGroupSyntax,
        in context: some MacroExpansionContext
    ) -> [ScannedRoute] {
        var routes: [ScannedRoute] = []
        for member in declaration.memberBlock.members {
            guard let function = member.decl.as(FunctionDeclSyntax.self) else { continue }
            routes.append(contentsOf: RouteScanning.scanRoutes(of: function, in: context))
        }
        return routes
    }

    /// Duplicates are checked on the *combined* path — two methods that only
    /// collide once a `@Controller` base path is applied are exactly as
    /// wrong as two that collide without one.
    private static func validateNoDuplicateRoutes(
        _ routes: [(route: ScannedRoute, path: String)],
        in context: some MacroExpansionContext
    ) -> Bool {
        var seen: [String: String] = [:]  // "METHOD path" → method name
        var valid = true
        for (route, path) in routes {
            let key = "\(route.kind.httpMethod) \(path)"
            if let existing = seen[key] {
                context.diagnoseError(
                    "mapping.duplicate",
                    "Route '\(key)' is declared by both '\(existing)' and '\(route.methodName)' in this controller.",
                    at: route.node
                )
                valid = false
            }
            seen[key] = route.methodName
        }
        return valid
    }

    /// `@Controller`'s own base-path argument (Spring-style combination —
    /// see the macro declaration's doc comment). Returns `""` for "no base
    /// The `pipelines:` argument's source text, re-embedded verbatim into
    /// every generated RouteRegistration — or nil for the default lane.
    /// Verbatim like @Component's `scope:`: the expression is evaluated in
    /// the expansion, so `[.defaultLane, "admin"]` and a constant both work.
    private static func parsePipelines(_ node: AttributeSyntax) -> String? {
        guard let arguments = node.arguments?.as(LabeledExprListSyntax.self) else { return nil }
        for argument in arguments where argument.label?.text == "pipelines" {
            return argument.expression.trimmedDescription
        }
        return nil
    }

    /// path" — omitted, explicit `nil`, empty string, or bare `"/"` are all
    /// the identity element for `RouteScanning.combinePaths`.
    private static func parseBasePath(
        _ node: AttributeSyntax,
        in context: some MacroExpansionContext
    ) -> String {
        guard let arguments = node.arguments?.as(LabeledExprListSyntax.self),
              let first = arguments.first, first.label == nil
        else { return "" }
        if first.expression.trimmedDescription == "nil" { return "" }
        guard let literal = first.expression.as(StringLiteralExprSyntax.self) else {
            context.diagnoseError(
                "controller.path.nonliteral",
                "@Controller's path must be a string literal — the route table is built at compile time (§4).",
                at: first.expression
            )
            return ""
        }
        var path = ""
        for segment in literal.segments {
            guard let text = segment.as(StringSegmentSyntax.self) else {
                context.diagnoseError(
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
            context.diagnoseError(
                "controller.path",
                "@Controller path '\(path)' must start with '/'.",
                at: node
            )
            return ""
        }
        return path
    }

    // MARK: - Validation (mirrors ComponentMacro)

    /// Final class or struct only, same rule and reasoning as `@Component`.
    /// Returns the declared type name for use in route sources.
    private static func validateAttachmentTarget(
        _ declaration: some DeclGroupSyntax,
        in context: some MacroExpansionContext
    ) -> String? {
        if let classDecl = declaration.as(ClassDeclSyntax.self) {
            let isFinal = classDecl.modifiers.contains { $0.name.tokenKind == .keyword(.final) }
            if !isFinal {
                context.diagnoseError(
                    "controller.nonfinal",
                    "@Controller requires a final class (or a struct). Mark '\(classDecl.name.text)' final.",
                    at: classDecl.name
                )
                return nil
            }
            return classDecl.name.text
        }
        if let structDecl = declaration.as(StructDeclSyntax.self) {
            return structDecl.name.text
        }
        context.diagnoseError(
            "controller.unsupported",
            "@Controller can only be attached to a final class or a struct.",
            at: declaration
        )
        return nil
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
                    || type.as(IdentifierTypeSyntax.self)?.name.text == "Optional" {
                    continue
                }
                context.diagnoseError(
                    "controller.uninitialized",
                    "Stored property '\(pattern.identifier.text)' of a @Controller type needs a default value — the generated init(_flight:) assigns only @Autowired/@ConfigValue properties.",
                    at: variable
                )
                valid = false
            }
        }
        return valid
    }

    // MARK: - Collection (mirrors ComponentMacro)

    private static func collectInjectedProperties(
        from declaration: some DeclGroupSyntax,
        in context: some MacroExpansionContext
    ) -> [InjectedProperty] {
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
                return .configValue(key: key, defaultValue: labeledArgumentSource(of: attr, label: "default"))
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

    private static func labeledArgumentSource(of attribute: AttributeSyntax, label: String) -> String? {
        guard let arguments = attribute.arguments?.as(LabeledExprListSyntax.self) else { return nil }
        for argument in arguments where argument.label?.text == label {
            return argument.expression.trimmedDescription
        }
        return nil
    }

    /// `_flightRegister` mirrors the type's own access level so the generated
    /// cross-module `flightRegisterAll` can call it (Flight Core P-1).
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
