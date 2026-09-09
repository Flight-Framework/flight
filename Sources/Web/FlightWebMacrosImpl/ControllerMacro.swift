import FlightRouteScan
import SwiftDiagnostics
import FlightMacroSupport
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// `@Controller` (§4). Expands like Flight Core's `@Component` — a
/// parameterized initializer over its `@Inject`/`@ConfigValue` properties —
/// with one purely additive difference: it also emits one route *factory* per
/// mapped method, each carrying (HTTP method, path pattern, encoded handler
/// thunk) and building the controller to run that method as a
/// `RouteRegistration` value. Routing is not a distinct system from dependency
/// injection.
///
/// `@Controller`'s own optional path argument is a base path, combined with
/// every mapped method's path (Spring's class+method `@RequestMapping`
/// combination rule — see `RouteScanning.combinePaths`); the combination is
/// resolved to a single literal at macro-expansion time, so it costs nothing
/// at runtime and duplicate-route detection runs on the already-combined
/// paths.
///
/// The injection half (`@Inject`/`@ConfigValue` handling, attachment and
/// storage validation) deliberately mirrors ComponentMacro line for line —
/// same diagnostics, same generated shapes — so a controller author's mental
/// model transfers from components unchanged. The authoritative expansions
/// are the fixtures in FlightWebMacroTests.
public struct ControllerMacro: MemberMacro, ExtensionMacro {

    // MARK: - Injected-property model (mirrors ComponentMacro)

    // MARK: - MemberMacro

    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard validateAttachmentTarget(declaration, in: context) != nil else { return [] }

        let properties = collectInjectedProperties(from: declaration, in: context)
        guard validateQualifierDisambiguation(properties, in: context) else { return [] }
        guard validateNonInjectedStorage(declaration, injected: properties, in: context) else { return [] }

        let basePath = RouteScanning.basePath(
            of: node, diagnostics: MacroRouteDiagnostics(context: context))
        let routes = collectRoutes(from: declaration, in: context)
        let combinedRoutes = routes.map { route in
            (route: route, path: RouteScanning.combinePaths(basePath, route.path))
        }
        guard validateNoDuplicateRoutes(combinedRoutes, in: context) else { return [] }

        let access = registrationAccess(for: declaration)

        // A route's own `pipelines:` replaces the controller's rather than
        // adding to it — the only rule that can express both "public
        // controller, one authenticated route" and "authenticated
        // controller, one public route". Saying nothing inherits.
        let controllerPipelines = RouteScanning.pipelines(of: node)
        // The per-route factories are the whole of what a controller emits for
        // wiring now: each builds the controller and runs one method. The
        // composition root's `flightRoutes(graph)` calls them. The container
        // era's init(_flight:) and _flightRegister thunks are gone.
        var factories: [DeclSyntax] = []
        for (index, (route, path)) in combinedRoutes.enumerated() {
            let pipelines = RouteScanning.resolvedPipelines(
                route: route.pipelinesText, controller: controllerPipelines)
            if let routePipelines = route.pipelinesText {
                diagnoseSecurityNarrowing(
                    controller: controllerPipelines, route: routePipelines,
                    at: route.attribute, method: route.methodName, in: context)
            }
            factories.append(
                DeclSyntax(
                    stringLiteral: routeFactory(
                        for: route, path: path, pipelines: pipelines, index: index)))
        }

        let parameterInit = parameterizedInitializer(
            properties: properties, access: access, declaration: declaration)
        return [parameterInit].compactMap { $0 } + factories
    }

    /// The name of one route's factory. Unique per route rather than per
    /// method, because one method may carry several route attributes.
    private static func factoryName(for route: ScannedRoute, index: Int) -> String {
        "_flightRoute_\(route.methodName)_\(index)"
    }

    /// One route, as a factory taking the controller it should call.
    ///
    /// The whole registration lives here — path, kind, lanes, body mode, body
    /// decoding, return encoding, upgrade shaping — parameterised by *how* the
    /// controller is obtained and by nothing else. That parameter is the seam
    /// COMPOSITION-MIGRATION.md §2.1a needs: `flightRoutes` passes a closure
    /// that constructs the controller per request from a `FlightGraph`, so a
    /// per-request controller stays per request and nothing else has to move —
    /// in particular the handler thunk stays in
    /// the macro, where the route scanner already lives, rather than being
    /// reimplemented in the generator and drifting from it.
    ///
    /// `make` takes the context so a constructor can use request values; one that
    /// needs none simply ignores it.
    private static func routeFactory(
        for route: ScannedRoute, path: String, pipelines: String?, index: Int
    ) -> String {
        let kind = route.kind.isUpgrade ? ".upgrade(.webSocket)" : ".http"

        var call = "controller.\(route.methodName)(context"
        if route.bodyTypeText != nil { call += ", body: body" }
        call += ")"
        if route.isAsync { call = "await \(call)" }
        if route.isThrows { call = "try \(call)" }

        var handlerLines: [String] = ["let controller = try make(context)"]
        if let bodyType = route.bodyTypeText {
            handlerLines.append(
                "let body = try FlightWeb.decodeRequestBody(\(bodyType).self, from: context)")
        }
        if route.kind.isUpgrade {
            handlerLines.append("let upgradeHandler = \(call)")
            handlerLines.append(
                "return FlightWeb.Response.upgrade(handler: upgradeHandler, context: context)")
        } else if route.returnTypeText != nil {
            handlerLines.append("let result = \(call)")
            handlerLines.append("return try FlightWeb.encodeResponse(result, for: context)")
        } else {
            handlerLines.append("\(call)")
            handlerLines.append("return FlightWeb.Response.noContent")
        }

        let pipelinesClause = pipelines.map { ", pipelines: \($0)" } ?? ""
        let bodyModeClause: String
        if route.isStreamingBody {
            bodyModeClause = ", bodyMode: .streaming(maxBytes: \(route.maxBodyBytesText ?? "nil"))"
        } else if let maxBytes = route.maxBodyBytesText {
            bodyModeClause = ", bodyMode: .buffered(maxBytes: \(maxBytes))"
        } else {
            bodyModeClause = ""
        }

        var lines: [String] = []
        lines.append(
            "static func \(factoryName(for: route, index: index))(_ make: @escaping @Sendable (FlightWeb.RequestContext) throws -> Self) -> FlightWeb.RouteRegistration {"
        )
        lines.append(
            "    FlightWeb.RouteRegistration(method: \"\(route.kind.httpMethod)\", path: \"\(path)\", kind: \(kind), source: String(reflecting: Self.self) + \".\(route.methodName)\"\(pipelinesClause)\(bodyModeClause)) { context in"
        )
        for line in handlerLines {
            lines.append("        \(line)")
        }
        lines.append("    }")
        lines.append("}")
        return lines.joined(separator: "\n")
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

    // MARK: - Route collection

    private static func collectRoutes(
        from declaration: some DeclGroupSyntax,
        in context: some MacroExpansionContext
    ) -> [ScannedRoute] {
        var routes: [ScannedRoute] = []
        for member in declaration.memberBlock.members {
            guard let function = member.decl.as(FunctionDeclSyntax.self) else { continue }
            routes.append(
                contentsOf: RouteScanning.scanRoutes(
                    of: function, diagnostics: MacroRouteDiagnostics(context: context)))
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
                    "route.duplicate",
                    "Route '\(key)' is declared by both '\(existing)' and '\(route.methodName)' in this controller.",
                    at: route.node
                )
                valid = false
            }
            seen[key] = route.methodName
        }
        return valid
    }

    /// The `pipelines:` argument's source text, re-embedded verbatim into
    /// every generated RouteRegistration — or nil for the default lane.
    /// Verbatim like @Component's `scope:`: the expression is evaluated in
    /// the expansion, so `[.defaultLane, "admin"]` and a constant both work.

    /// The canonical security lanes, in every spelling a declaration site can
    /// use. A macro sees source text and nothing else — it cannot resolve
    /// `.authenticated` to a value — so recognizing a security lane means
    /// recognizing how it is written. This is why the lanes are canonical
    /// names on `PipelineLane` rather than free-form strings: with arbitrary
    /// strings there is nothing here to match, and the warning below cannot
    /// exist.
    private static let securityLaneSpellings: Set<String> = [
        ".authentication", ".authenticated",
        "PipelineLane.authentication", "PipelineLane.authenticated",
        "\"authentication\"", "\"authenticated\"",
    ]

    private static let publicLaneSpellings: Set<String> = [
        ".public", "PipelineLane.public", "\"public\"",
    ]

    /// Warns when a route replaces its controller's lanes with a set that
    /// drops the controller's authentication, without saying `.public`.
    ///
    /// A warning rather than an error, deliberately: narrowing is legitimate,
    /// and the build should not fail on a judgment the author is entitled to
    /// make. But dropping authentication silently is the mistake worth
    /// catching, and naming `.public` *is* the acknowledgment — it records
    /// the intent in the declaration instead of a comment beside it, and
    /// makes "every deliberately-public route under an authenticated
    /// controller" greppable. This mirrors the warn-vs-error discipline
    /// already in `flight-registration-gen`.
    private static func diagnoseSecurityNarrowing(
        controller: String?, route: String, at attribute: AttributeSyntax,
        method: String, in context: some MacroExpansionContext
    ) {
        guard let controller else { return }
        let controllerLanes = laneSpellings(in: controller)
        let routeLanes = laneSpellings(in: route)

        let dropped = controllerLanes
            .filter(securityLaneSpellings.contains)
            .filter { !routeLanes.contains($0) }
        guard !dropped.isEmpty else { return }
        // `.public` is the acknowledgment; having said it, the author is done.
        guard routeLanes.isDisjoint(with: publicLaneSpellings) else { return }
        // Still running some other security lane is a swap, not a drop.
        guard routeLanes.isDisjoint(with: securityLaneSpellings) else { return }

        context.diagnoseWarning(
            "route.pipelines.narrowing",
            """
            '\(method)' replaces its controller's pipelines and drops \
            \(dropped.sorted().joined(separator: ", ")), so this route runs without \
            authentication. A route's 'pipelines:' replaces the controller's rather than \
            adding to it. If that is intended, say 'pipelines: [.public]' — that is how a \
            deliberately public route records the decision.
            """,
            at: attribute
        )
    }

    /// The lane spellings in a `pipelines:` argument's source text, split on
    /// the array literal's commas. Text-level by necessity, and only ever
    /// used to compare against the canonical spellings above.
    private static func laneSpellings(in text: String) -> Set<String> {
        func trimmed(_ s: Substring) -> String {
            var slice = s
            while let first = slice.first, first.isWhitespace || first == "[" {
                slice = slice.dropFirst()
            }
            while let last = slice.last, last.isWhitespace || last == "]" {
                slice = slice.dropLast()
            }
            return String(slice)
        }
        return Set(
            text.split(separator: ",")
                .map(trimmed)
                .filter { !$0.isEmpty })
    }

    /// `@Controller`'s own base-path argument (Spring-style combination — see
    /// the macro declaration's doc comment). Returns `""` for "no base path":
    /// omitted, explicit `nil`, empty string, and bare `"/"` are all the
    /// identity element for `RouteScanning.combinePaths`.

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
        // Two properties collide when they would resolve the *same key* —
        // same type and same qualifier, "no qualifier" being a key of its
        // own. Mirrors `ComponentMacro`, including why: flight-data registers
        // the primary datasource unqualified as well as by name, so
        // `@Inject var pool: PostgresDataSource` beside
        // `@Inject("analytics") var analytics: PostgresDataSource` names two
        // different registrations and used to be refused anyway.
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
                    "Stored property '\(pattern.identifier.text)' of a @Controller type needs a default value — the generated initializer assigns only @Inject/@ConfigValue properties.",
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

    /// The generated initializer and route factories mirror the type's own
    /// access level so the generated cross-module composition root can build
    /// and register it (Flight Core P-1).
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
