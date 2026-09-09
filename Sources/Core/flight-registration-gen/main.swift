// flight-registration-gen
//
// Invoked by FlightRegistrationPlugin with one argument: the path to a JSON
// manifest describing the target being built, the source files of every
// module in scope (the target itself plus its recursive source-module
// dependencies that sit atop FlightCore), and the output path.
//
// Mechanism note: symbol graphs are
// not available to build tool plugins, so this tool scans *source text* with
// SwiftParser. It emits one flat `flightRegisterAll(_:)` for the whole graph
// visible from the target, which preserves the aggregation contract ("one
// generated function registers everything") with fewer moving parts than
// per-target functions calling each other — dependency targets' generated
// outputs are not visible across plugin work directories anyway.
//
// Besides the per-component thunk calls, flightRegisterAll also carries
// synthesized *existential bridges*: for every `@Inject var x: (any P)`
// demand whose protocol has exactly one scanned conformer, a registration of
// the existential key routing to that conformer (see the synthesis section
// below for the exact rules and escape hatches).
//
// Diagnostics are printed to stderr in `path:line:col: severity: message`
// form, which SwiftPM surfaces in build logs and IDEs.

import FlightConfigCore
import FlightRouteScan
import Foundation
import SwiftParser
import SwiftSyntax

// MARK: - Manifest (shape shared with Plugins/FlightRegistrationPlugin)

struct Manifest: Codable {
    struct Module: Codable {
        let name: String
        let files: [String]
    }
    /// The module the generated file is compiled into.
    let targetModuleName: String
    /// All modules to scan, target's own module included.
    let modules: [Module]
    let output: String
    /// Directory of the package that owns the target — where flight.yaml
    /// lives when the app has one. Optional: older manifests (and tests)
    /// omit it, which skips the config-key check.
    let packageDirectory: String?
}

// MARK: - Scan model

struct ScannedComponent {
    let module: String
    let typeName: String
    /// The registrable attribute's name — `Service`, `Repository`,
    /// `Controller`, … — which is what decides the stereotype. Kept because
    /// the generator delegates registration to the macro's `_flightRegister`
    /// thunk and so never had to know it, while a static component list does.
    let attributeName: String
    let isPublic: Bool
    /// Source text of the registrable attribute's `scope:` argument. Defaults
    /// to `.singleton`, exactly like the macro's parseComponentArguments —
    /// the two must agree or a synthesized bridge would mirror a scope the
    /// thunk never registered.
    let scopeText: String
    /// Source text of the `qualifier:` argument, nil when absent.
    let qualifierText: String?
    /// Type names the declaration conforms to: its inheritance clause, plus
    /// any `extension T: P` found in scanned sources (merged after the scan —
    /// extensions are the part of the conformance picture an attached macro
    /// can never see).
    var conformanceNames: [String]
    let injectTypeNames: [String]
    /// The property names behind `injectTypeNames`, positionally. The
    /// generated initializer labels its parameters by property name, so a
    /// composition function calling it needs these and not the type names —
    /// `UserRepository(pool: dataSource)`, never `(postgresDataSource:)`.
    let injectPropertyNames: [String]
    /// `@Inject` types whose property carries a `flight:hand-registered`
    /// marker comment — the author's acknowledgment that the type is
    /// registered by hand in a module's `configure(_:)` (invisible to this
    /// scanner, P-2) and the missing-registration warning should not fire.
    /// Still participates in cycle detection.
    let acknowledgedTypeNames: [String]
    /// Every dependency, injected and acknowledged alike, in **declaration
    /// order** with its property name.
    ///
    /// The generated initializer takes its parameters in declaration order, so
    /// emitting `inject` then `acknowledged` mislabels the call whenever a
    /// `flight:hand-registered` property is declared before an injected one —
    /// `UserController(sockets:validator:)` against an
    /// `init(validator:sockets:)`. Caught by the demo's `SocketController`.
    let dependencyOrder: [(type: String, label: String)]

    /// As `injectPropertyNames`, for the acknowledged edges.
    let acknowledgedPropertyNames: [String]
    /// Carries a `flight:module-registered` marker: the type is registrable
    /// (it has the macro, and therefore a `_flightRegister` thunk) but its
    /// *existence in an application* is a runtime question its own module
    /// answers — so `flightRegisterAll` must not register it.
    ///
    /// Without this the scan registers every annotated type in every app that
    /// merely links the package. `Authentication` is the worked example: it
    /// injects `(any TokenValidator)`, which only a security module provides,
    /// and `freeze()` eagerly builds every singleton — so an app that linked
    /// FlightSecurityCore without including a security module failed to boot.
    let isModuleRegistered: Bool
    let configValues: [ScannedConfigValue]
    let file: String
    let line: Int
}

/// One required-key site — an explicit `@ConfigValue`, or a plain property
/// inside `@Settings` whose key is derived from its name. `key` is nil when
/// the expression isn't a plain string literal (interpolation) — not
/// statically checkable, so the check skips it and the runtime throw remains
/// the backstop.
struct ScannedConfigValue {
    enum Source {
        /// An explicit `@ConfigValue("...")` attribute.
        case explicitConfigValue
        /// A plain property inside `@Settings`, whose attribute the message
        /// must not claim was written — the whole point of `@Settings` is
        /// that it wasn't.
        case implicitSettingsField
    }
    let key: String?
    let hasDefault: Bool
    let source: Source
    let file: String
    let line: Int
}

// MARK: - Route scanning

/// One route, as the generator sees it: the same scan `@Controller` runs,
/// through the same parser (`FlightRouteScan`), so the manifest and the
/// expansion cannot disagree about a path, a method, or a lane.
struct ScannedControllerRoute {
    /// The controller's type name, and the route's position within it —
    /// together they name the factory `@Controller` generated,
    /// `_flightRoute_<method>_<index>`.
    let controllerTypeName: String
    let methodName: String
    let indexInController: Int
    let httpMethod: String
    /// Controller base path combined with the route's own, by the same rule
    /// the macro applies.
    let path: String
    /// `String(reflecting:)`-shaped origin, matching the qualifier the macro
    /// gives the route's `RouteRegistration`.
    let source: String
    /// Resolved lanes, verbatim: the route's own `pipelines:` when it has
    /// one — replacement, not addition — otherwise the controller's.
    let pipelinesText: String?
    let isUpgrade: Bool
    let file: String
    let line: Int
}

/// Swallows what the scan reports.
///
/// Deliberate, and the reason is double-reporting: `@Controller` already
/// scans every one of these functions and already diagnoses a non-literal
/// path, a static handler, a bad signature, an upgrade with a body. The
/// generator runs over the same sources in the same build, so anything it
/// reported would arrive at the author twice, at the same line, in the same
/// build log.
///
/// The macro owns the reporting; the generator owns the manifest. A route
/// the macro rejects simply does not reach the manifest — which is correct,
/// because the macro did not register it either.
struct SilentRouteDiagnostics: RouteDiagnostics {
    func error(_ id: String, _ message: String, at node: some SyntaxProtocol) {}
    func warning(_ id: String, _ message: String, at node: some SyntaxProtocol) {}
}

/// One `container.pipeline(_:_:)` declaration.
///
/// Lanes are the other half of what dispatch reads out of the container
/// (COMPOSITION-MIGRATION.md §2.9): `collectMiddleware(lane:)` and
/// `declaredMiddlewareLanes()` are container-as-data exactly the way
/// `collectRoutes()` is, so the manifest has to carry them too.
struct ScannedPipelineLane {
    /// Normalized lane name: `"default"` for the unnamed form, the literal's
    /// content for `pipeline("admin")`, the member's name for
    /// `pipeline(.authenticated)`. nil when the argument is neither — a
    /// computed lane, which the manifest records but cannot name.
    let lane: String?
    /// The lane argument's source text, verbatim; nil for the unnamed form.
    let laneText: String?
    /// Middleware type names in declared order — outermost first, which is
    /// the order the block is written in.
    let middleware: [String]
    /// The type whose body holds this call, when there is one.
    ///
    /// Nearly always a `FlightModule`, and that is the point: the call runs
    /// only if the application includes that module, so a lane the scan sees
    /// is not necessarily a lane the container gets. The same conditional
    /// -inclusion fact `flight:module-registered` exists to record for
    /// components.
    let declaredIn: String?
    let module: String
    let file: String
    let line: Int
}

/// One `FlightModule` conformer and the modules it pulls in.
///
/// The edges `_flightResolveModuleOrder` walks. It topologically sorts the
/// DAG and `Bootstrap` runs `configure` in that order, which is what makes
/// registration sequence — and therefore lane order — a property of the
/// module graph rather than of file order.
struct ScannedModule {
    let typeName: String
    /// Every initializer the module declares, as (labels, types).
    ///
    /// All of them, not the first: `ActuatorModule` declares `init()` *and*
    /// `init(processEnvironment:)` — a test seam — and `FlightPubSubModule`
    /// declares `init(configuration:adapter:)` *and* an `init()` that traps
    /// because it cannot be built from its type. Neither "first" nor "prefer
    /// `init()`" picks correctly in both cases. The composer chooses the one
    /// it can actually supply.
    let initializers: [(labels: [String], types: [String], throws: Bool)]
    /// Dependency type names as written, `.self` and any generic argument
    /// stripped: `PostgresDataModule<PrimaryDataSource>.self` is
    /// `PostgresDataModule`.
    let dependencies: [String]
    /// The module's public stored properties — what it *provides*.
    ///
    /// D11 says a module is a value that holds what it provides, which makes
    /// its stored properties the outputs of the composition graph:
    /// `FlightPubSubValkeyModule.adapter` is what
    /// `FlightPubSubModule(configuration:adapter:)` takes. Matching them by
    /// type is how one module's output becomes another's input without either
    /// naming the other.
    let provides: [(name: String, type: String)]
    let module: String
}

/// A route family mounted by a framework convenience, or a route registered
/// by hand.
///
/// The three imperative doors are not one problem. `assets(at:root:)` and
/// `uploads(at:store:)` expand one call into several routes whose paths the
/// framework derives from a prefix the application supplies — so the *mount*
/// is the declaration, and it is scannable at the call site even though the
/// `registerRoute` calls inside the convenience are not.
/// `registerChannelSocket` is the same shape with one route.
/// `registerRoute` itself is the raw escape hatch, and the only one where a
/// path can be genuinely uncomputable.
struct ScannedMount {
    enum Kind: String {
        case assets
        case uploads
        case socket
        /// A direct `registerRoute` — no prefix to derive routes from.
        case route
    }
    let kind: Kind
    /// The literal prefix or path, when the argument is a plain string
    /// literal. nil for an interpolated or computed one, which is the case
    /// the manifest cannot carry and the acknowledgment exists for.
    let path: String?
    /// The `pipelines:` argument's source text, verbatim.
    let pipelinesText: String?
    /// Carries a `flight:hand-registered` marker — the author's
    /// acknowledgment that this route is invisible to the scan, the same
    /// convention `@Inject` uses for a type registered by hand.
    let isAcknowledged: Bool
    let declaredIn: String?
    let module: String
    let file: String
    let line: Int
}

extension ScannedMount.Kind {
    /// The framework spellings that put a route in the table without an
    /// attribute. `registerChannelSocket` is a wrapper over `registerRoute`,
    /// but it is recognized separately because its call site carries a
    /// literal path where the wrapper's does not.
    init?(callee name: String) {
        switch name {
        case "assets": self = .assets
        case "uploads": self = .uploads
        case "registerChannelSocket": self = .socket
        case "registerRoute": self = .route
        default: return nil
        }
    }
}

/// Finds `container.pipeline { }` calls and `FlightModule` declarations.
///
/// A second pass rather than work folded into `ComponentVisitor`: that one
/// returns `.skipChildren` at every type declaration, deliberately — nested
/// registrable types are a non-goal — so it never descends into the method
/// bodies where these calls live. Walking twice costs one more traversal of
/// an already-parsed tree and leaves component collection untouched.
///
/// Lanes and module edges are collected together because neither is useful
/// without the other: a lane declaration says what a stack contains, and the
/// module graph says when it runs.
final class ModuleVisitor: SyntaxVisitor {
    let module: String
    let file: String
    let converter: SourceLocationConverter
    var lanes: [ScannedPipelineLane] = []
    var modules: [ScannedModule] = []
    var mounts: [ScannedMount] = []
    /// Module types named in a `modules:` argument — the bootstrap list.
    ///
    /// This is the fact that makes conditional inclusion static. It was
    /// treated as a runtime question because the container was the only
    /// mechanism that knew it, but the list is a literal array in the
    /// application's own source, and that source is scanned.
    var bootstrapModules: [String] = []
    private var typeStack: [String] = []

    init(module: String, file: String, tree: SourceFileSyntax) {
        self.module = module
        self.file = file
        self.converter = SourceLocationConverter(fileName: file, tree: tree)
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        typeStack.append(node.name.text)
        collectModule(
            named: node.name.text, inheritance: node.inheritanceClause, members: node.memberBlock)
        return .visitChildren
    }
    override func visitPost(_ node: ClassDeclSyntax) { typeStack.removeLast() }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        typeStack.append(node.name.text)
        collectModule(
            named: node.name.text, inheritance: node.inheritanceClause, members: node.memberBlock)
        return .visitChildren
    }
    override func visitPost(_ node: StructDeclSyntax) { typeStack.removeLast() }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        typeStack.append(node.name.text)
        collectModule(
            named: node.name.text, inheritance: node.inheritanceClause, members: node.memberBlock)
        return .visitChildren
    }
    override func visitPost(_ node: EnumDeclSyntax) { typeStack.removeLast() }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        typeStack.append(node.extendedType.trimmedDescription)
        return .visitChildren
    }
    override func visitPost(_ node: ExtensionDeclSyntax) { typeStack.removeLast() }


    /// Records a `FlightModule` conformer and the `dependencies` it declares.
    ///
    /// Conformance is matched by name, like everything else in this scanner —
    /// a build tool has source text and no symbol graph. A type that conforms
    /// only through an extension is missed, which is the same blind spot the
    /// component scan has and the same reason `extension T: P` clauses are
    /// merged in separately there.
    private func collectModule(
        named name: String, inheritance: InheritanceClauseSyntax?, members: MemberBlockSyntax
    ) {
        guard let inheritance,
              inheritance.inheritedTypes.contains(where: {
                  baseName($0.type.trimmedDescription) == "FlightModule"
              })
        else { return }

        var dependencies: [String] = []
        for member in members.members {
            guard let variable = member.decl.as(VariableDeclSyntax.self),
                  variable.modifiers.contains(where: { $0.name.tokenKind == .keyword(.static) }),
                  variable.bindings.first?.pattern.as(IdentifierPatternSyntax.self)?
                      .identifier.text == "dependencies"
            else { continue }
            for element in arrayElements(of: variable) {
                // `Foo<Bar>.self` -> `Foo`. The runtime treats each
                // specialization as its own type; for ordering, the edge is
                // what matters and the base name carries it.
                guard let member = element.as(MemberAccessExprSyntax.self),
                      member.declName.baseName.tokenKind == .keyword(.self),
                      let base = member.base
                else { continue }
                dependencies.append(base.trimmedDescription)
            }
        }
        // The initializer a composer would call. `init()` conformances are
        // the ordinary case today; a module that has moved to owning its
        // components declares what it needs instead.
        var initializers: [(labels: [String], types: [String], throws: Bool)] = []
        for member in members.members {
            guard let initializer = member.decl.as(InitializerDeclSyntax.self) else { continue }
            let parameters = initializer.signature.parameterClause.parameters
            initializers.append(
                (
                    labels: parameters.map {
                        $0.firstName.tokenKind == .wildcard ? "_" : $0.firstName.text
                    },
                    types: parameters.map { $0.type.trimmedDescription },
                    throws: initializer.signature.effectSpecifiers?.throwsClause != nil
                ))
        }
        // A module declaring none conforms through the protocol's own
        // requirement, which is `init()`.
        if initializers.isEmpty { initializers = [(labels: [], types: [], throws: false)] }
        // Stored properties, with an explicit type and reachable from the
        // composition root. Computed ones are excluded because `var service:
        // (any Service)?` is one, and a module's service is bootstrap's to
        // collect, not another module's to take.
        var provides: [(name: String, type: String)] = []
        for member in members.members {
            guard let variable = member.decl.as(VariableDeclSyntax.self),
                  !variable.modifiers.contains(where: {
                      $0.name.tokenKind == .keyword(.static)
                          || $0.name.tokenKind == .keyword(.private)
                          || $0.name.tokenKind == .keyword(.fileprivate)
                  })
            else { continue }
            for binding in variable.bindings {
                guard binding.accessorBlock == nil,
                      let type = binding.typeAnnotation?.type.trimmedDescription,
                      let identifier = binding.pattern.as(IdentifierPatternSyntax.self)?
                          .identifier.text
                else { continue }
                provides.append((name: identifier, type: type))
            }
        }
        modules.append(
            ScannedModule(
                typeName: name, initializers: initializers,
                dependencies: dependencies, provides: provides, module: module))
    }

    /// The elements of the array literal a `dependencies` property returns,
    /// whether it is written as an implicit-return getter or with `return`.
    private func arrayElements(of variable: VariableDeclSyntax) -> [ExprSyntax] {
        guard let accessors = variable.bindings.first?.accessorBlock else {
            // `static let dependencies: [...] = [ ... ]`
            if let value = variable.bindings.first?.initializer?.value.as(ArrayExprSyntax.self) {
                return value.elements.map(\.expression)
            }
            return []
        }
        let statements: CodeBlockItemListSyntax
        switch accessors.accessors {
        case .getter(let items): statements = items
        case .accessors(let list):
            guard let getter = list.first(where: { $0.accessorSpecifier.tokenKind == .keyword(.get) }),
                  let body = getter.body
            else { return [] }
            statements = body.statements
        }
        for statement in statements {
            if let array = statement.item.as(ExprSyntax.self)?.as(ArrayExprSyntax.self) {
                return array.elements.map(\.expression)
            }
            if let returned = statement.item.as(ReturnStmtSyntax.self)?.expression?
                .as(ArrayExprSyntax.self) {
                return returned.elements.map(\.expression)
            }
        }
        return []
    }


    /// Records one mount or hand-registered route.
    private func collectMount(_ kind: ScannedMount.Kind, _ node: FunctionCallExprSyntax) {
        // `assets(at:)` and `uploads(at:)` label the prefix; the socket and
        // raw-route forms pass it positionally — second for `registerRoute`,
        // which leads with the HTTP method.
        var pathExpression: ExprSyntax?
        switch kind {
        case .assets, .uploads:
            pathExpression = node.arguments.first { $0.label?.text == "at" }?.expression
        case .socket:
            pathExpression = node.arguments.first { $0.label == nil }?.expression
        case .route:
            let unlabeled = Array(node.arguments.filter { $0.label == nil })
            pathExpression = unlabeled.count >= 2 ? unlabeled[1].expression : nil
        }

        var path: String?
        if let literal = pathExpression?.as(StringLiteralExprSyntax.self) {
            let segments = literal.segments.compactMap { $0.as(StringSegmentSyntax.self) }
            // An interpolated path is the uncomputable case, not a path.
            if segments.count == literal.segments.count {
                path = segments.map(\.content.text).joined()
            }
        } else if pathExpression == nil, kind == .socket {
            // `registerChannelSocket()` defaults to "/socket".
            path = "/socket"
        }

        mounts.append(
            ScannedMount(
                kind: kind,
                path: path,
                pipelinesText: node.arguments.first { $0.label?.text == "pipelines" }?
                    .expression.trimmedDescription,
                isAcknowledged: node.leadingTrivia.description.contains(
                    "flight:hand-registered"),
                declaredIn: typeStack.last,
                module: module,
                file: file,
                line: converter.location(for: node.position).line
            ))
    }


    /// Records the module types a `modules:` argument names.
    private func collectBootstrapModules(_ node: FunctionCallExprSyntax) {
        guard let argument = node.arguments.first(where: { $0.label?.text == "modules" }),
            let array = argument.expression.as(ArrayExprSyntax.self)
        else { return }
        for element in array.elements {
            guard let member = element.expression.as(MemberAccessExprSyntax.self),
                member.declName.baseName.tokenKind == .keyword(.self),
                let base = member.base
            else { continue }
            // Kept whole: `FlightWebModule<FlightTransport>` is one module,
            // and the generic argument is the transport it was chosen with —
            // which the composer has to write back out to construct it.
            bootstrapModules.append(base.trimmedDescription)
        }
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        // `modules:` can appear on `Flight.run`, `Flight.bootstrap` or
        // `Flight.assemble`; the label is what identifies it, not the callee.
        collectBootstrapModules(node)

        guard let callee = node.calledExpression.as(MemberAccessExprSyntax.self) else {
            return .visitChildren
        }
        // Mounts and hand-registered routes: the three imperative doors, plus
        // the raw one. Recognized by method name, like `pipeline` above — a
        // build tool matches source text, and these are the framework's own
        // spellings.
        if let kind = ScannedMount.Kind(callee: callee.declName.baseName.text) {
            collectMount(kind, node)
            return .visitChildren
        }

        guard callee.declName.baseName.text == "pipeline",
              // The lane block is a trailing closure in every form; a
              // `pipeline` call without one is somebody else's method.
              let block = node.trailingClosure
        else { return .visitChildren }

        // The lane: absent (default), a string literal, or `.name`.
        var lane: String? = "default"
        var laneText: String? = nil
        if let argument = node.arguments.first, argument.label == nil {
            laneText = argument.expression.trimmedDescription
            if let literal = argument.expression.as(StringLiteralExprSyntax.self) {
                lane = literal.segments.compactMap {
                    $0.as(StringSegmentSyntax.self)?.content.text
                }.joined()
                // An interpolated lane name is not statically knowable.
                if literal.segments.count != literal.segments.compactMap({
                    $0.as(StringSegmentSyntax.self)
                }).count {
                    lane = nil
                }
            } else if let member = argument.expression.as(MemberAccessExprSyntax.self),
                      member.base == nil {
                lane = member.declName.baseName.text
            } else {
                lane = nil
            }
        }

        // `X.self` per statement, in order.
        var middleware: [String] = []
        for statement in block.statements {
            guard let expression = statement.item.as(ExprSyntax.self),
                  let member = expression.as(MemberAccessExprSyntax.self),
                  member.declName.baseName.tokenKind == .keyword(.self),
                  let base = member.base
            else { continue }
            middleware.append(base.trimmedDescription)
        }

        lanes.append(
            ScannedPipelineLane(
                lane: lane,
                laneText: laneText,
                middleware: middleware,
                declaredIn: typeStack.last,
                module: module,
                file: file,
                line: converter.location(for: node.position).line
            ))
        return .visitChildren
    }
}

// MARK: - Syntax visitor

/// Collects top-level `@Component`/`@Controller` types. Nested registrable
/// types are a deliberate v1 non-goal (registration by qualified nested name
/// is easy to add; supporting it silently before deciding it's wanted is not).
final class ComponentVisitor: SyntaxVisitor {
    /// Attribute names that mark a type as `_FlightRegistrable`. This is the
    /// Flight Web's "one registration pipeline, different entry kinds"
    /// extension point: `@Controller` expands to the same `_flightRegister`
    /// thunk as `@Component`, so the generator's only job is knowing the
    /// *name* — it never references another package's types, keeping the
    /// "Core imports nothing above it" boundary intact at the code level.
    /// Every attribute that makes a type registrable.
    ///
    /// A new one must be added here as well as given a macro, or the macro
    /// generates a `_flightRegister` thunk that nothing ever calls and the
    /// type is silently never registered. That is exactly what happened to
    /// `@Scheduler`: it shipped in 0.2.0 with a working macro, a working
    /// runtime, and no entry here, so a scheduled job never ran. There is a
    /// test below pinning this list against the macros the framework
    /// actually declares.
    static let registrableAttributes: Set<String> = [
        "Component", "Service", "Repository", "Controller", "Scheduler", "Settings", "Middleware",
    ]

    let module: String
    let file: String
    let converter: SourceLocationConverter
    var components: [ScannedComponent] = []
    var routes: [ScannedControllerRoute] = []
    /// `extension T: P` clauses seen in this file, keyed later by the extended
    /// type's base name. Collected file-wide (not just for known components —
    /// the component's declaration may live in a different file).
    var extensionConformances: [(typeName: String, protocols: [String])] = []

    init(module: String, file: String, tree: SourceFileSyntax) {
        self.module = module
        self.file = file
        self.converter = SourceLocationConverter(fileName: file, tree: tree)
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        collect(
            name: node.name.text, attributes: node.attributes,
            modifiers: node.modifiers, members: node.memberBlock,
            inheritanceClause: node.inheritanceClause, position: node.position,
            leadingTrivia: node.leadingTrivia.description)
        return .skipChildren
    }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        collect(
            name: node.name.text, attributes: node.attributes,
            modifiers: node.modifiers, members: node.memberBlock,
            inheritanceClause: node.inheritanceClause, position: node.position,
            leadingTrivia: node.leadingTrivia.description)
        return .skipChildren
    }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        if let clause = node.inheritanceClause, !clause.inheritedTypes.isEmpty {
            extensionConformances.append(
                (
                    typeName: node.extendedType.trimmedDescription,
                    protocols: clause.inheritedTypes.map { $0.type.trimmedDescription }
                ))
        }
        return .skipChildren
    }


    /// Scans one `@Controller`'s members for routes and records them with
    /// their combined paths and resolved lanes.
    private func collectRoutes(
        controller: String, attribute: AttributeSyntax, members: MemberBlockSyntax
    ) {
        let silent = SilentRouteDiagnostics()
        let base = RouteScanning.basePath(of: attribute, diagnostics: silent)
        let controllerPipelines = RouteScanning.pipelines(of: attribute)

        var index = 0
        for member in members.members {
            guard let function = member.decl.as(FunctionDeclSyntax.self) else { continue }
            for route in RouteScanning.scanRoutes(of: function, diagnostics: silent) {
                let location = converter.location(for: route.node.position)
                defer { index += 1 }
                routes.append(
                    ScannedControllerRoute(
                        controllerTypeName: controller,
                        methodName: route.methodName,
                        indexInController: index,
                        httpMethod: route.kind.httpMethod,
                        path: RouteScanning.combinePaths(base, route.path),
                        source: "\(module).\(controller).\(route.methodName)",
                        pipelinesText: RouteScanning.resolvedPipelines(
                            route: route.pipelinesText, controller: controllerPipelines),
                        isUpgrade: route.kind.isUpgrade,
                        file: file,
                        line: location.line
                    )
                )
            }
        }
    }

    private func collect(
        name: String,
        attributes: AttributeListSyntax,
        modifiers: DeclModifierListSyntax,
        members: MemberBlockSyntax,
        inheritanceClause: InheritanceClauseSyntax?,
        position: AbsolutePosition,
        leadingTrivia: String
    ) {
        let registrable = attributes.lazy
            .compactMap { $0.as(AttributeSyntax.self) }
            .first {
                guard let name = $0.attributeName.as(IdentifierTypeSyntax.self)?.name.text else {
                    return false
                }
                return Self.registrableAttributes.contains(name)
            }
        guard let registrable else { return }
        let isPublic = modifiers.contains {
            $0.name.tokenKind == .keyword(.public) || $0.name.tokenKind == .keyword(.open)
        }
        // @Settings binds every plain property implicitly — there is no
        // per-property @ConfigValue attribute to scan for the common case,
        // only a property name and the type's own namespace argument. The
        // key the macro will generate is derived the same way here as there
        // (ConfigKeyNaming.kebabCase, shared rather than duplicated) so a
        // required key with no default can get the same compile-time
        // flight.yaml check @ConfigValue's explicit form already has.
        // Routes, for the static manifest (COMPOSITION-MIGRATION.md §2.9).
        // Same parser the macro uses, so a path combined here and a path
        // combined in the expansion are combined by one implementation.
        if registrable.attributeName.as(IdentifierTypeSyntax.self)?.name.text == "Controller" {
            collectRoutes(controller: name, attribute: registrable, members: members)
        }

        let isSettingsType =
            registrable.attributeName.as(IdentifierTypeSyntax.self)?.name.text == "Settings"
        let settingsNamespace = isSettingsType ? literalKey(of: registrable) : nil

        var inject: [String] = []
        var injectNames: [String] = []
        var acknowledged: [String] = []
        var acknowledgedNames: [String] = []
        var dependencyOrder: [(type: String, label: String)] = []
        var configValues: [ScannedConfigValue] = []
        for member in members.members {
            guard let variable = member.decl.as(VariableDeclSyntax.self) else { continue }
            if hasAttribute(variable.attributes, named: "Inject"),
                let binding = variable.bindings.first,
                let type = binding.typeAnnotation?.type.trimmedDescription
            {
                let propertyName =
                    binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text ?? ""
                // `member.description` spans the member's leading trivia
                // through its last token's trailing trivia, so the marker is
                // found whether it sits on the line above the property or as
                // a same-line trailing comment.
                dependencyOrder.append((type: type, label: propertyName))
                if member.description.contains("flight:hand-registered") {
                    acknowledged.append(type)
                    acknowledgedNames.append(propertyName)
                } else {
                    inject.append(type)
                    injectNames.append(propertyName)
                }
            }
            if let attribute = attribute(of: variable.attributes, named: "ConfigValue") {
                let propertyLocation = converter.location(for: variable.position)
                // A property initializer *is* a default — the macro treats it
                // as one (`getIfPresent ?? default`). Reading only the
                // attribute's `default:` label made
                // `@ConfigValue("legacy.key") var x: String = "fallback"`
                // a hard build error saying the key is missing from
                // flight.yaml and has no default, on code that runs correctly.
                let hasInitializer = variable.bindings.contains { $0.initializer != nil }
                configValues.append(
                    ScannedConfigValue(
                        key: literalKey(of: attribute),
                        hasDefault: hasLabeledArgument(attribute, label: "default")
                            || hasInitializer,
                        source: .explicitConfigValue,
                        file: file,
                        line: propertyLocation.line
                    ))
                continue
            }

            if let namespace = settingsNamespace,
                !hasAttribute(variable.attributes, named: "Inject")
            {
                for binding in variable.bindings {
                    guard binding.accessorBlock == nil,
                        binding.initializer == nil,
                        let pattern = binding.pattern.as(IdentifierPatternSyntax.self),
                        let type = binding.typeAnnotation?.type,
                        !type.is(OptionalTypeSyntax.self),
                        type.as(IdentifierTypeSyntax.self)?.name.text != "Optional"
                    else { continue }
                    let propertyLocation = converter.location(for: variable.position)
                    let key = "\(namespace).\(ConfigKeyNaming.kebabCase(pattern.identifier.text))"
                    configValues.append(
                        ScannedConfigValue(
                            key: key, hasDefault: false, source: .implicitSettingsField,
                            file: file, line: propertyLocation.line
                        ))
                }
            }
        }
        let location = converter.location(for: position)
        components.append(
            ScannedComponent(
                module: module,
                typeName: name,
                attributeName: registrable.attributeName
                    .as(IdentifierTypeSyntax.self)?.name.text ?? "Component",
                isPublic: isPublic,
                scopeText: labeledArgumentSource(of: registrable, label: "scope") ?? ".singleton",
                qualifierText: labeledArgumentSource(of: registrable, label: "qualifier"),
                conformanceNames: inheritanceClause?.inheritedTypes.map {
                    $0.type.trimmedDescription
                } ?? [],
                injectTypeNames: inject,
                injectPropertyNames: injectNames,
                acknowledgedTypeNames: acknowledged,
                dependencyOrder: dependencyOrder,
                acknowledgedPropertyNames: acknowledgedNames,
            isModuleRegistered: leadingTrivia.contains("flight:module-registered"),
                configValues: configValues,
                file: file,
                line: location.line
            ))
    }

    private func hasAttribute(_ attributes: AttributeListSyntax, named name: String) -> Bool {
        attribute(of: attributes, named: name) != nil
    }

    private func attribute(of attributes: AttributeListSyntax, named name: String)
        -> AttributeSyntax?
    {
        for element in attributes {
            guard let attribute = element.as(AttributeSyntax.self) else { continue }
            if attribute.attributeName.as(IdentifierTypeSyntax.self)?.name.text == name {
                return attribute
            }
        }
        return nil
    }

    /// The key argument's literal content — nil when it isn't a plain string
    /// literal, which makes the site unverifiable statically.
    private func literalKey(of attribute: AttributeSyntax) -> String? {
        guard let arguments = attribute.arguments?.as(LabeledExprListSyntax.self),
            let first = arguments.first, first.label == nil,
            let literal = first.expression.as(StringLiteralExprSyntax.self)
        else { return nil }
        var key = ""
        for segment in literal.segments {
            guard let text = segment.as(StringSegmentSyntax.self) else { return nil }
            key += text.content.text
        }
        return key
    }

    private func hasLabeledArgument(_ attribute: AttributeSyntax, label: String) -> Bool {
        guard let arguments = attribute.arguments?.as(LabeledExprListSyntax.self) else {
            return false
        }
        return arguments.contains { $0.label?.text == label }
    }

    /// Source text of a labeled argument, nil when absent or literally `nil` —
    /// mirroring the macro's labeledArgumentSource, so generated bridges can
    /// never disagree with the thunk about scope or qualifier.
    private func labeledArgumentSource(of attribute: AttributeSyntax, label: String) -> String? {
        guard let arguments = attribute.arguments?.as(LabeledExprListSyntax.self) else {
            return nil
        }
        for argument in arguments where argument.label?.text == label {
            let text = argument.expression.trimmedDescription
            return text == "nil" ? nil : text
        }
        return nil
    }
}

// MARK: - Diagnostics

var errorCount = 0

// Top-level vars in main.swift are MainActor-isolated under Swift 6; these
// helpers touch them, so they join the same isolation (the tool is strictly
// single-threaded top-level code either way).
@MainActor
func emit(_ severity: String, _ message: String, file: String, line: Int) {
    FileHandle.standardError.write(
        "\(file):\(line):1: \(severity): \(message)\n".data(using: .utf8)!)
    if severity == "error" { errorCount += 1 }
}

// MARK: - Main

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(
        "usage: flight-registration-gen <manifest.json>\n".data(using: .utf8)!)
    exit(2)
}

let manifest: Manifest
do {
    let data = try Data(contentsOf: URL(fileURLWithPath: arguments[1]))
    manifest = try JSONDecoder().decode(Manifest.self, from: data)
} catch {
    FileHandle.standardError.write(
        "flight-registration-gen: cannot read manifest: \(error)\n".data(using: .utf8)!)
    exit(2)
}

var components: [ScannedComponent] = []
/// Imports written by the target's own sources.
///
/// The generated file is a separate file, so it inherits nothing. It has
/// always emitted the modules that *declare components*, which is enough for
/// `flightRegisterAll` — every type it names is one of those. `FlightGraph`
/// is not: its root parameters are typed by whatever an `@Inject` said, and
/// those types come from wherever the application imports them —
/// `PostgresDataSource` from FlightDataPostgres, which declares no scanned
/// component and so was never imported here.
var targetImports: Set<String> = []
var routes: [ScannedControllerRoute] = []
var lanes: [ScannedPipelineLane] = []
var moduleGraph: [ScannedModule] = []
var bootstrapModules: [String] = []
var mounts: [ScannedMount] = []
var extensionConformances: [(typeName: String, protocols: [String])] = []
for module in manifest.modules {
    for file in module.files {
        guard let source = try? String(contentsOf: URL(fileURLWithPath: file), encoding: .utf8)
        else {
            emit(
                "warning", "Flight codegen could not read source file (skipped).", file: file,
                line: 1)
            continue
        }
        // Cheap pre-filter before full parse; scanning is on the hot path of
        // every build of the target. "extension" is included because a
        // conformance-only `extension T: P` file feeds bridge synthesis —
        // this admits most real files, but the parse it saves was always the
        // cheap part; the filter's remaining job is skipping generated and
        // resource-adjacent sources.
        guard
            ComponentVisitor.registrableAttributes.contains(where: { source.contains("@\($0)") })
                || source.contains("extension")
                // A module body declaring lanes, or carrying the
                // dependency edges lane order is derived from, has no
                // registrable attribute to match on.
                || source.contains(".pipeline")
                || source.contains("FlightModule")
                || source.contains("registerRoute")
                || source.contains("registerChannelSocket")
                || source.contains("modules:")
        else { continue }
        if module.name == manifest.targetModuleName {
            for line in source.split(separator: "\n") {
                let text = line.trimmingCharacters(in: .whitespaces)
                guard text.hasPrefix("import ") else { continue }
                let name = text.dropFirst("import ".count).trimmingCharacters(in: .whitespaces)
                // `@_exported` and submodule paths are not plain names.
                if !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
                    targetImports.insert(name)
                }
            }
        }
        let tree = Parser.parse(source: source)
        let visitor = ComponentVisitor(module: module.name, file: file, tree: tree)
        visitor.walk(tree)
        components.append(contentsOf: visitor.components)
        routes.append(contentsOf: visitor.routes)
        extensionConformances.append(contentsOf: visitor.extensionConformances)

        if source.contains(".pipeline") || source.contains("FlightModule") {
            let moduleScan = ModuleVisitor(module: module.name, file: file, tree: tree)
            moduleScan.walk(tree)
            lanes.append(contentsOf: moduleScan.lanes)
            moduleGraph.append(contentsOf: moduleScan.modules)
            if module.name == manifest.targetModuleName {
                bootstrapModules.append(contentsOf: moduleScan.bootstrapModules)
            }
            mounts.append(contentsOf: moduleScan.mounts)
        }
    }
}

/// A module's identity for matching, with its generic argument stripped.
///
/// `FlightWebModule<FlightTransport>` and `FlightWebModule` are the same
/// module named two ways: the declaration has no generic argument, a
/// bootstrap list and a `dependencies` entry do. Matching uses this; emitting
/// uses the text as written, because the composer has to construct it.
func moduleKey(_ text: String) -> String {
    var name = text
    if let angle = name.firstIndex(of: "<") { name = String(name[..<angle]) }
    return baseName(name)
}

/// Name-level matching everywhere below compares base names — the last dotted
/// component — so `FlightDemo.UserRepositoryProtocol` and
/// `UserRepositoryProtocol` refer to the same seam.
func baseName(_ typeName: String) -> String {
    typeName.split(separator: ".").last.map(String.init) ?? typeName
}

// Merge extension-declared conformances into the scanned components.
if !extensionConformances.isEmpty {
    var extras: [String: [String]] = [:]
    for entry in extensionConformances {
        extras[baseName(entry.typeName), default: []].append(contentsOf: entry.protocols)
    }
    for index in components.indices {
        if let added = extras[components[index].typeName] {
            components[index].conformanceNames.append(contentsOf: added)
        }
    }
}

// MARK: - Existential bridge synthesis
//
// The stereotype macros register a component under its CONCRETE type key;
// `@Inject var x: (any P)` resolves the EXISTENTIAL key. Nothing used to
// populate that key, so every protocol seam cost a hand-written bridge in a
// module's configure(_:) plus a marker comment silencing the warning below.
// The scanner sees both sides of the seam — the demand in @Inject type
// text, the supply in inheritance clauses and extensions — so when a demanded
// protocol has exactly one scanned conformer, the bridge is generated into
// flightRegisterAll instead.
//
// Demand-driven on purpose: binding only what some @Inject actually asks
// for means marker conformances (Sendable, Codable, a superclass) never
// produce registrations — nobody autowires `(any Sendable)`.
//
// A `// flight:hand-registered` marker on the demanding property suppresses
// synthesis: it is the author's statement that the key is populated by hand
// in a configure(_:) body this scanner cannot see (P-2), and a synthesized
// duplicate would trap at registration. Ambiguity (multiple scanned
// conformers) also synthesizes nothing — warning, not error, because a hand
// bridge may already resolve it invisibly; guessing a winner silently would
// be worse than asking.

/// `(any P)` / `any P` → "P". Nil for optionals (they resolve under a
/// different key), compositions (`any P & Q`), generics, and non-existential
/// types — those demands fall back to the warning + hand-bridge path.
func existentialProtocolName(_ typeText: String) -> String? {
    var text = typeText.trimmingCharacters(in: .whitespaces)
    if text.hasSuffix("?") || text.hasSuffix("!") { return nil }
    while text.hasPrefix("("), text.hasSuffix(")") {
        text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
    }
    guard text.hasPrefix("any ") else { return nil }
    let name = String(text.dropFirst("any ".count)).trimmingCharacters(in: .whitespaces)
    guard !name.isEmpty,
        name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." })
    else { return nil }
    return name
}

/// The key two types are matched on when one is provided and the other
/// demanded: base name, with optionality, parentheses, `any`, and generic
/// arguments stripped.
///
/// `existentialProtocolName` deliberately refuses an optional — it decides
/// whether to synthesize a bridge, and `(any P)?` is not a registrable
/// component. Composition asks a different question: `adapter: (any
/// DistributedPubSubAdapter)?` and `let adapter: any DistributedPubSubAdapter`
/// are the same seam, and the `?` only says the parameter may be omitted.
func providedTypeKey(_ typeText: String) -> String {
    var text = typeText.trimmingCharacters(in: .whitespaces)
    while text.hasSuffix("?") || text.hasSuffix("!") {
        text = String(text.dropLast()).trimmingCharacters(in: .whitespaces)
    }
    while text.hasPrefix("("), text.hasSuffix(")") {
        text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
    }
    if text.hasPrefix("any ") {
        text = String(text.dropFirst("any ".count)).trimmingCharacters(in: .whitespaces)
    }
    return moduleKey(text)
}

/// `[T]` and `Array<T>` -> `T`; anything else -> nil.
///
/// Both spellings, because a module author writes whichever reads better and
/// the composer has only source text to go on.
func arrayElementType(_ typeText: String) -> String? {
    var text = typeText.trimmingCharacters(in: .whitespaces)
    while text.hasSuffix("?") || text.hasSuffix("!") {
        text = String(text.dropLast()).trimmingCharacters(in: .whitespaces)
    }
    if text.hasPrefix("["), text.hasSuffix("]") {
        let inner = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        // `[K: V]` is a dictionary, not an aggregate of contributions.
        return inner.contains(":") ? nil : inner
    }
    if text.hasPrefix("Array<"), text.hasSuffix(">") {
        return String(text.dropFirst("Array<".count).dropLast())
            .trimmingCharacters(in: .whitespaces)
    }
    return nil
}

struct SynthesizedBridge {
    /// The protocol name as written at the demand site (module qualification
    /// preserved) — re-embedded verbatim in the generated register call.
    let protocolName: String
    let component: ScannedComponent
}

@MainActor
func synthesizeBridges() -> [SynthesizedBridge] {
    var suppressed: Set<String> = []
    for component in components {
        for acknowledged in component.acknowledgedTypeNames {
            if let name = existentialProtocolName(acknowledged) {
                suppressed.insert(baseName(name))
            }
        }
    }

    // First demand site wins for spelling/diagnostics; the key is the same
    // type however it is spelled.
    var demands: [String: (protocolName: String, demandedBy: ScannedComponent)] = [:]
    for component in components {
        for dependency in component.injectTypeNames {
            guard let name = existentialProtocolName(dependency) else { continue }
            let base = baseName(name)
            if demands[base] == nil { demands[base] = (name, component) }
        }
    }

    var bridges: [SynthesizedBridge] = []
    for base in demands.keys.sorted() {
        guard !suppressed.contains(base) else { continue }
        let demand = demands[base]!
        // Module-registered types are not bridge candidates: a bridge
        // resolving one asserts it exists, and whether it exists is exactly
        // the runtime question its module answers. Bridging to it would
        // reintroduce the eager-freeze failure the marker exists to prevent.
        let conformers = components.filter { component in
            !component.isModuleRegistered
                && component.conformanceNames.contains { baseName($0) == base }
        }
        switch conformers.count {
        case 0:
            continue  // The missing-registration warning below covers this.
        case 1:
            bridges.append(
                SynthesizedBridge(protocolName: demand.protocolName, component: conformers[0]))
        default:
            emit(
                "warning",
                "@Inject type '(any \(demand.protocolName))' in \(demand.demandedBy.typeName) has \(conformers.count) scanned conformers (\(conformers.map(\.typeName).sorted().joined(separator: ", "))) — no bridge was generated. Register the existential by hand in a module's configure(_:) and acknowledge the property with a `// flight:hand-registered` comment.",
                file: demand.demandedBy.file, line: demand.demandedBy.line
            )
        }
    }
    return bridges
}
let bridges = synthesizeBridges()
let bridgedProtocolBaseNames = Set(bridges.map { baseName($0.protocolName) })

// MARK: - Validation

// Missing-registration checks are *warnings*: components registered by hand inside
// a module's configure(_:) are invisible to a source scanner, so an unknown
// type name is suspicious, not proven wrong. Cycles among scanned components
// are errors: those are fully decidable from what the scanner sees.
let knownTypeNames = Set(components.map(\.typeName))
// Types the container answers for without anyone registering them. A demand
// for one of these is satisfied at runtime no matter what the scanner sees,
// so warning about it would be a false positive on correct code — and a
// false positive that appears on every build is how a useful warning gets
// tuned out.
let alwaysAvailable: Set<String> = [
    "Configuration", "FlightCore.Configuration", "FlightConfig.Configuration",
    // The container resolves to itself, which is how a gateway — a channel
    // or a scheduled job that must open its own scope — gets one.
    "Container", "FlightCore.Container",
]

for component in components {
    for dependency in component.injectTypeNames {
        // Demands satisfied by a synthesized bridge are no longer suspicious.
        if let name = existentialProtocolName(dependency),
            bridgedProtocolBaseNames.contains(baseName(name))
        {
            continue
        }
        let written = dependency.trimmingCharacters(in: .whitespaces)
        // Optional injection is not supported, and stripping the `?` here hid
        // that: the check passed, then the macro generated `resolve(Cache?.self)`
        // whose `Optional<Cache>` key is never registered, and the app failed
        // at bootstrap with `notRegistered` — against Docs/core.md's promise
        // that missing registrations are reported at build time.
        if written.hasSuffix("?") {
            emit(
                "error",
                """
                @Inject does not support optional types: '\(written)' in \
                \(component.typeName) would resolve Optional<\
                \(written.dropLast())>, which nothing registers. Drop the '?' if the \
                dependency is required, or resolve it by hand where absence is \
                meaningful.
                """,
                file: component.file, line: component.line
            )
            continue
        }
        let base = written
        // Compared on the base name, as the bridge check above already does.
        // Comparing the written text against bare scanned names warned on
        // every correctly-qualified `@Inject var x: MyLib.Foo` — an
        // always-on false positive, which is how a warning teaches people to
        // stop reading warnings.
        let known =
            knownTypeNames.contains(base) || alwaysAvailable.contains(base)
            || knownTypeNames.contains(baseName(base))
            || alwaysAvailable.contains(baseName(base))
        if !known {
            emit(
                "warning",
                "@Inject type '\(base)' in \(component.typeName) is not a scanned @Component. If it is hand-registered in a module's configure(_:), acknowledge it with a `// flight:hand-registered` comment on the property; otherwise resolution will fail at startup.",
                file: component.file, line: component.line
            )
        }
    }
}

// Static cycle detection over the @Inject edges (name-level, qualifier-blind).
@MainActor
func detectCycles() {
    let byName = Dictionary(components.map { ($0.typeName, $0) }, uniquingKeysWith: { a, _ in a })
    var finished: Set<String> = []
    var inProgress: Set<String> = []

    func visit(_ name: String, stack: [String]) {
        guard let component = byName[name] else { return }
        if finished.contains(name) { return }
        if inProgress.contains(name) {
            let cycleStart = stack.firstIndex(of: name) ?? 0
            let chain = (stack[cycleStart...] + [name]).joined(separator: " → ")
            emit(
                "error", "Dependency cycle among @Component types: \(chain)", file: component.file,
                line: component.line)
            return
        }
        inProgress.insert(name)
        // Acknowledged (marker-carrying) dependencies keep their edges here:
        // the marker silences the missing-registration warning, never cycle
        // detection.
        for dependency in (component.injectTypeNames + component.acknowledgedTypeNames)
        where byName[dependency] != nil {
            visit(dependency, stack: stack + [name])
        }
        inProgress.remove(name)
        finished.insert(name)
    }

    for component in components {
        visit(component.typeName, stack: [])
    }
}
detectCycles()

// MARK: - Captive dependency (compile-time case)
//
// A singleton is constructed once, at `freeze()`, and outlives every request.
// One that injects a `.scoped` component either fails the freeze — the
// factory finds no ambient `Scope.active` and throws `scopeRequired`, naming
// the type — or, on a dynamic path that does have a scope, captures one
// request's instance for the life of the process.
//
// The scan already knows both scopes and already walks `@Inject` edges for
// `detectCycles()`, so this is a comparison on an existing traversal. Moving
// it from startup to build time is the whole of the improvement: the runtime
// check stays, and stays correct, until composition removes the lifetime
// concept entirely (COMPOSITION-MIGRATION.md §2.2).
@MainActor
func diagnoseRemovedLifetimes() {
    for component in components
    where component.scopeText.hasSuffix(".scoped")
        || component.scopeText.hasSuffix(".transient")
    {
        let lifetime = component.scopeText.hasSuffix(".scoped") ? ".scoped" : ".transient"
        let message =
            "'\(component.typeName)' declares `scope: \(lifetime)`, which no longer exists. "
            + "Singleton is the only lifetime: nothing needed the others, and removing them "
            + "removed the captive-dependency class with them. Per-request state travels on "
            + "`RequestContext` — the authenticated principal is the worked example — and a "
            + "pooled connection is leased per operation by the repository that holds the pool. "
            + "Drop the argument."
        emit("error", message, file: component.file, line: component.line)
    }
}
diagnoseRemovedLifetimes()

// Cross-module registration requires the component be visible to the target's
// generated code.
for component in components
where component.module != manifest.targetModuleName && !component.isPublic {
    emit(
        "error",
        "@Component type '\(component.typeName)' in module \(component.module) must be public to be registered from \(manifest.targetModuleName)'s generated flightRegisterAll.",
        file: component.file, line: component.line
    )
}

// MARK: - Undeclared lanes (compile-time case)
//
// A route naming a lane nobody declared fails when dispatch is built —
// at bootstrap, naming the route and the lane, never as a 500. The scan
// knows both halves before the binary exists, so it can say so at the
// declaration instead (§2.7 asked for this).
//
// A warning rather than an error, deliberately. The scan reaches the target
// and its recursive *source* dependencies, so a lane declared inside a
// binary dependency is invisible to it — and a build error there would fail
// an application that runs correctly. `UndeclaredLaneError` at bootstrap
// stays the enforcement; this is the early word, and it is silent whenever
// it cannot be sure.
@MainActor
func diagnoseUndeclaredLanes() {
    // A lane whose name is computed makes the whole set unknowable: it might
    // be the very lane a route is asking for. Say nothing rather than guess.
    guard lanes.allSatisfy({ $0.lane != nil }) else { return }

    var declared = Set(lanes.compactMap(\.lane))
    // `DispatchBuilder` provides both without a declaration: an application
    // with no middleware is legal, and `.public` means "explicitly no lanes".
    declared.insert("default")
    declared.insert("public")

    for route in routes {
        guard let text = route.pipelinesText else { continue }
        guard let named = laneNames(in: text) else { continue }
        for lane in named where !declared.contains(lane) {
            emit(
                "warning",
                """
                Route \(route.httpMethod) \(route.path) runs through pipeline lane \
                '\(lane)', which no `container.pipeline("\(lane)") { }` declares. \
                Declare the lane (an empty block is legal), or remove it from the \
                route's pipelines — otherwise this fails when dispatch is built.
                """,
                file: route.file, line: route.line
            )
        }
    }
}

/// Lane names from a `pipelines:` argument's source text — `[.authenticated]`,
/// `["admin"]`, `[.default, "admin"]`. nil when any element is neither a
/// canonical member nor a string literal, since a computed lane cannot be
/// checked and one unknowable element makes the list unknowable.
func laneNames(in text: String) -> [String]? {
    let body = text.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
    guard !body.isEmpty else { return [] }
    var names: [String] = []
    for element in body.split(separator: ",") {
        let piece = element.trimmingCharacters(in: .whitespaces)
        if piece.hasPrefix("."), piece.dropFirst().allSatisfy({ $0.isLetter || $0.isNumber }) {
            names.append(String(piece.dropFirst()))
        } else if piece.hasPrefix("\""), piece.hasSuffix("\""), piece.count >= 2 {
            names.append(String(piece.dropFirst().dropLast()))
        } else {
            return nil
        }
    }
    return names
}

diagnoseUndeclaredLanes()

/// Every module an application actually includes: the ones it listed, plus
/// everything those pull in through `dependencies`.
///
/// The runtime resolves the same set at bootstrap with
/// `_flightResolveModuleOrder`; this is that walk over the scanned edges,
/// against roots read from the `modules:` argument in the application's own
/// source. It is what makes "does this subsystem exist in this app" a
/// build-time question instead of a runtime one — the assumption behind
/// `flight:module-registered`, and the thing D11 removes the need for.
///
/// Empty when the target names no bootstrap list, which is the ordinary case
/// for a library: it includes nothing because it starts nothing.
@MainActor
func resolveIncludedModules() -> [String] {
    let byName = Dictionary(
        moduleGraph.map { (moduleKey($0.typeName), $0) }, uniquingKeysWith: { a, _ in a })
    var ordered: [String] = []
    var seen: Set<String> = []

    func visit(_ text: String) {
        let key = moduleKey(text)
        guard !seen.contains(key) else { return }
        seen.insert(key)
        // Dependencies first, the order `configure` runs in.
        for dependency in byName[key]?.dependencies ?? [] {
            visit(dependency)
        }
        // As written, generic argument and all: this is what constructs it.
        ordered.append(text)
    }
    for root in bootstrapModules { visit(root) }
    return ordered
}
let includedModules = resolveIncludedModules()

// MARK: - Routes the manifest cannot see
//
// `registerRoute` is the escape hatch beside the macro path, the way Core's
// `register` is beside `@Component`, and it is deliberately arbitrary Swift:
// a path can come from configuration or a loop. So the scan cannot enumerate
// what it registers, and a static route table that silently omitted it would
// turn a working route into a 404 with nothing to grep for.
//
// The same answer the component scan already uses: acknowledge it at the call
// site with `// flight:hand-registered`, and name every skipped route in the
// generated file so nothing disappears quietly.
//
// Mounts (`assets`, `uploads`, `registerChannelSocket`) are exempt: their
// call site carries the prefix the framework derives routes from, so they are
// recorded rather than skipped.
@MainActor
func reportHandRegisteredRoutes() {
    for mount in mounts where mount.kind == .route && !mount.isAcknowledged {
        emit(
            "warning",
            """
            This route is registered by hand, so the static route manifest \
            cannot see it. Declare it with @GetRoute/@PostRoute on a \
            @Controller, or acknowledge it with a `// flight:hand-registered` \
            comment above the call.
            """,
            file: mount.file, line: mount.line
        )
    }
}
reportHandRegisteredRoutes()

// MARK: - @ConfigValue key check (compile-time case)
//
// A @ConfigValue key with no `default:` must exist in flight.yaml — the base
// layer, present in every environment. Absent from both is a *compile error*
// at the @ConfigValue site: the check needs only flight.yaml plus static
// context, so per the project-wide rule it must not wait for runtime. The
// runtime-only case (key present in base but a specific flight-{env}.yaml
// failed to supply its real value) stays a thrown ConfigError at bootstrap.
//
// Policy when flight.yaml doesn't exist: skip. A pure-library package has no
// config files — the check belongs to (and runs in) the app target whose
// plugin invocation scans that library's sources alongside its flight.yaml.
@MainActor
func checkConfigKeys() {
    guard let packageDirectory = manifest.packageDirectory else { return }
    let baseURL = URL(fileURLWithPath: packageDirectory)
        .appendingPathComponent(FlightConfigFiles.base)
    guard FileManager.default.fileExists(atPath: baseURL.path) else { return }

    let baseKeys: Set<String>
    do {
        // .none: build-machine env vars are meaningless here, and the check
        // only needs the key *structure*. Same parser as the runtime, so the
        // two can never disagree about what keys the file defines.
        baseKeys = try FlightYAMLDocument(contentsOf: baseURL, substitution: .none).keys
    } catch let error as ConfigLoadError {
        if case .parseFailed(_, let line, let column, let message) = error {
            FileHandle.standardError.write(
                "\(baseURL.path):\(line):\(column): error: \(message)\n".data(using: .utf8)!
            )
            errorCount += 1
        } else {
            emit(
                "error", "flight.yaml could not be loaded for the @ConfigValue key check: \(error)",
                file: baseURL.path, line: 1)
        }
        return
    } catch {
        emit(
            "error", "flight.yaml could not be loaded for the @ConfigValue key check: \(error)",
            file: baseURL.path, line: 1)
        return
    }

    for component in components {
        for configValue in component.configValues {
            guard let key = configValue.key, !configValue.hasDefault else { continue }
            guard !baseKeys.contains(key) else { continue }
            let message: String
            switch configValue.source {
            case .explicitConfigValue:
                message =
                    "@ConfigValue key '\(key)' in \(component.typeName) is missing from flight.yaml and has no default. Add the key to flight.yaml (the base layer — a ${VAR} placeholder is fine for env-supplied values), or provide default:."
            case .implicitSettingsField:
                // No @ConfigValue was written here — @Settings derived this
                // key from the property's own name — so the message must not
                // claim an attribute that isn't there.
                message =
                    "'\(key)' in \(component.typeName) is missing from flight.yaml and the property has no default. Add the key to flight.yaml (the base layer — a ${VAR} placeholder is fine for env-supplied values), or give the property a default value."
            }
            emit("error", message, file: configValue.file, line: configValue.line)
        }
    }
}
checkConfigKeys()

if errorCount > 0 { exit(1) }

/// Lane declarations in the order their modules configure.
///
/// `collectMiddleware(lane:)` sorts by registration sequence, and
/// registration sequence is module sequence: `_flightResolveModuleOrder`
/// walks the DAG depth-first and appends each module *after* its
/// dependencies, then `Bootstrap` runs `configure` in that order. Scan order
/// has no such notion — it follows the file list, which puts the target's
/// own module first, so a framework module's middleware landed after the
/// application's when the runtime puts it before.
///
/// The same walk, over the edges scanned from `static var dependencies`.
/// Where two modules have no path between them the runtime order comes from
/// the bootstrap list, which is not in scope here; those keep scan order
/// relative to each other, which is the honest answer rather than a guess.
@MainActor
func lanesInModuleOrder() -> [ScannedPipelineLane] {
    let byName = Dictionary(
        moduleGraph.map { (moduleKey($0.typeName), $0) }, uniquingKeysWith: { a, _ in a })
    var position: [String: Int] = [:]
    var finished: Set<String> = []
    var inProgress: Set<String> = []

    func visit(_ name: String) {
        guard let module = byName[name], !finished.contains(name) else { return }
        // A cycle is ModuleGraphError.cycle at startup; nothing to add here
        // beyond not looping.
        guard !inProgress.contains(name) else { return }
        inProgress.insert(name)
        for dependency in module.dependencies {
            visit(moduleKey(dependency))
        }
        inProgress.remove(name)
        finished.insert(name)
        position[name] = position.count
    }

    for module in moduleGraph {
        visit(moduleKey(module.typeName))
    }

    // Stable: declarations from one module keep the order they were written
    // in, which is the order `configure` makes the calls.
    return lanes.enumerated().sorted { left, right in
        let leftModule = left.element.declaredIn.flatMap { position[$0] } ?? Int.max
        let rightModule = right.element.declaredIn.flatMap { position[$0] } ?? Int.max
        if leftModule != rightModule { return leftModule < rightModule }
        return left.offset < right.offset
    }.map(\.element)
}


/// The `Stereotype` a registrable attribute registers under.
///
/// Mirrors the macros' own mapping: `@Component` passes no `stereotype:` and
/// takes the parameter's `.component` default, and so does anything without
/// an explicit case here. `@Scheduler` is deliberately in that group —
/// `Stereotype` has no scheduler case, and inventing one in a build tool
/// would put the manifest and the runtime out of step.
func stereotype(forAttribute name: String) -> String {
    switch name {
    case "Service": return "service"
    case "Repository": return "repository"
    case "Controller": return "controller"
    case "Settings": return "settings"
    case "Middleware": return "middleware"
    default: return "component"
    }
}

/// Escapes text being re-embedded in a generated Swift string literal. Route
/// paths are already refused a quote or a backslash by the scanner, but the
/// lane text is an arbitrary expression, so this is not decorative.
func escaped(_ text: String) -> String {
    text.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
}

// MARK: - Emission

// Deterministic output: sort by (module, type). Stable output means stable
// builds and readable diffs of the generated file.
let sorted = components.sorted {
    ($0.module, $0.typeName) < ($1.module, $1.typeName)
}
// Registrable, but registered by their own module rather than by this scan:
// their presence in an app is a runtime question (a configuration gate, an
// optional subsystem) that no build-time scan can answer. Kept in `sorted`
// for validation and conformance analysis; excluded from the emitted calls.
let (moduleRegistered, autoRegistered) = (
    sorted.filter(\.isModuleRegistered), sorted.filter { !$0.isModuleRegistered }
)
let dependencyModules = Set(sorted.map(\.module)).subtracting([manifest.targetModuleName]).sorted()

let graphRegistrable = components.filter { !$0.isModuleRegistered }
// A controller is constructed per request by its route terminal, not
// held for the process — that is the whole point of §2.1a — so it is not
// a graph node. Unless something else injects it, in which case the
// graph has to build it like anything else.
let graphDependedUpon = Set(
graphRegistrable.flatMap { $0.injectTypeNames + $0.acknowledgedTypeNames }.map(baseName))
// Left out of the graph, and each for its own reason:
//
// - a controller is built per request by its route terminal, which is
//   the whole of §2.1a — unless something else injects it, in which case
//   the graph does have to build it;
// - `@Settings` calls `validate()` after construction and `@Scheduler`
//   registers its jobs, both inside their own thunk. Projecting those
//   would drop the extra, so the container keeps constructing them and
//   they arrive here as root parameters if anything depends on them.
let containerConstructed: Set<String> = ["settings", "scheduler"]
let graphNodes = graphRegistrable.filter { component in
    let kind = stereotype(forAttribute: component.attributeName)
    if containerConstructed.contains(kind) { return false }
    return kind != "controller" || graphDependedUpon.contains(baseName(component.typeName))
}

/// Which graph property holds each component the graph builds, by base name.
/// `flightRegisterAll` projects a registration onto it instead of
/// constructing a second copy.
let graphBindings: [String: String] = Dictionary(
    graphNodes.map { component in
        let name = baseName(component.typeName)
        return (name, name.prefix(1).lowercased() + name.dropFirst())
    },
    uniquingKeysWith: { a, _ in a })

var out = """
    // AUTO-GENERATED by flight-registration-gen — do not edit.
    // Target: \(manifest.targetModuleName)
    // Components: \(autoRegistered.count), existential bridges: \(bridges.count)
    // Module-registered (not registered here): \(moduleRegistered.count)

    import FlightCore

    """
for module in dependencyModules {
    out += "import \(module)\n"
}
// Plus what the target imports, for the types `FlightGraph`'s root
// parameters are written in. Sorted so the output is byte-stable.
for module in targetImports.sorted()
where module != "FlightCore" && !dependencyModules.contains(module) {
    out += "import \(module)\n"
}
out += """

    /// Registers every @Component visible from \(manifest.targetModuleName)
    /// (its own sources plus all Flight-based dependency modules). Call this
    /// from a FlightModule's configure(_:) or directly before freeze().

    """
// The graph is built by the composition root and handed in, so the parameter
// exists exactly when there is a graph to hand.
if graphRegistrable.isEmpty {
    out += "public func flightRegisterAll(_ container: FlightCore.Container) throws {\n"
} else {
    out += """
        /// - Parameter graph: Every component, already constructed — the
        ///   composition root builds it and passes it here. It used to be built
        ///   from the container at `freeze()`, so an application's components
        ///   were constructed by a factory rather than at the one place that
        ///   knows how the application is assembled.
        ///
        /// Internal rather than public: `FlightGraph` is internal — an
        /// application's components are internal by default and a public type
        /// cannot expose them — and the composition root is in this module
        /// too, so nothing needs either to be public.
        func flightRegisterAll(
            _ container: FlightCore.Container, graph: FlightGraph
        ) throws {

        """
}
// The graph first: every projected registration below resolves it, and an
// application with components but no routes needs it just as much as one
// with routes. Registration is deferred either way — nothing is constructed
// until freeze.
// Gated on the same condition the graph is *emitted* under, not on whether
// it has nodes. An application whose only component is a controller has an
// empty graph — and route terminals still resolve it, because that is where
// they reach root inputs and it is how they are written either way. Gating
// on `graphNodes` left that application emitting terminals that resolved a
// type nothing registered, which the skeleton template caught and a richer
// one could not.
if !graphRegistrable.isEmpty {
    out += "    // Projected, not built: route terminals resolve it to reach root\n"
    out += "    // inputs, and they see the instance the composition root made.\n"
    out += "    container.register(FlightGraph.self, scope: .singleton) { _ in graph }\n"
}
if autoRegistered.isEmpty {
    out += "\n    // No @Component types found in scope.\n"
} else {
    out += "\n"
    for component in autoRegistered {
        let qualified =
            component.module == manifest.targetModuleName
            ? component.typeName
            : "\(component.module).\(component.typeName)"
        // A component the graph builds is *projected* here rather than
        // constructed: one construction, in one place, with the container as
        // a view onto it. `context.resolve`, the existential bridges and
        // Actuator's introspection all keep working, and they see the same
        // instance a route terminal does.
        let kind = stereotype(forAttribute: component.attributeName)
        if let binding = graphBindings[baseName(component.typeName)] {
            let qualifierArgument = component.qualifierText.map { ", qualifier: \($0)" } ?? ""
            let stereotypeArgument = kind == "component" ? "" : ", stereotype: .\(kind)"
            out +=
                "    container.register(\(qualified).self\(qualifierArgument), scope: .singleton\(stereotypeArgument)) { _ in\n"
            out += "        graph.\(binding)\n"
            out += "    }\n"
        } else {
            // Its own thunk still constructs it. `@Settings` validates after
            // construction and `@Scheduler` registers its jobs, neither of
            // which a projection carries.
            //
            // A controller is here for a different reason: dispatch builds
            // one per request from the graph, so this registration serves
            // only introspection — Actuator groups the dashboard by
            // stereotype, and a controller absent from the container would
            // be absent from it. Its routes come from
            // `flightRoutes(_:)`, hence `includingRoutes: false`.
            let routesClause = kind == "controller" ? ", includingRoutes: false" : ""
            out += "    try \(qualified)._flightRegister(container\(routesClause))\n"
        }
    }
}
if !moduleRegistered.isEmpty {
    // Named, not silent: "why is my @Middleware not registered" should be
    // answerable by reading this file.
    out += "\n"
    out += "    // Marked `flight:module-registered` — their own module registers them,\n"
    out += "    // because whether they exist in an application is a runtime question:\n"
    for component in moduleRegistered {
        out += "    //   \(component.module).\(component.typeName)\n"
    }
}
if !bridges.isEmpty {
    // Emitted line by line rather than as a multiline literal: a multiline
    // literal strips indentation relative to its CLOSING delimiter, so a
    // formatter that re-indents the block silently changes the emitted text.
    // These carry their indentation explicitly and cannot drift.
    out += "\n"
    out += "    // Existential bridges (demand-driven): each `@Inject var _: (any P)`\n"
    out += "    // with exactly one scanned conformer resolves through that conformer,\n"
    out += "    // mirroring its scope. A `// flight:hand-registered` marker on the\n"
    out += "    // demanding property suppresses the bridge.\n"
    for bridge in bridges {
        let component = bridge.component
        let concrete =
            component.module == manifest.targetModuleName
            ? component.typeName
            : "\(component.module).\(component.typeName)"
        let qualifierArgument = component.qualifierText.map { ", qualifier: \($0)" } ?? ""
        // One lifetime, so one spelling. This used to branch: a scoped
        // conformer resolved through `resolveInActiveScope`, because by the
        // time the bridge factory ran the ambient scope was already bound and
        // the explicit form kept the captive-dependency error precise. Both
        // the lifetime and the scope went with §2.2.
        let resolveCall = "try c.resolve(\(concrete).self\(qualifierArgument))"
        out +=
            "    container.register((any \(bridge.protocolName)).self) { c in\n"
        out += "        \(resolveCall)\n"
        out += "    }\n"
    }
}
if !routes.isEmpty {
    out += "\n"
    out += "    // Routes last: their controllers are constructed per\n"
    out += "    // request from the graph, which needs every component\n"
    out += "    // registered first.\n"
    out += ""
}
out += "}\n"

/// What `FlightGraph`'s initializer takes, published by `emitFlightGraph` for
/// the composer to wire.
///
/// The graph's roots are exactly the things modules provide — a data source, a
/// token validator — so once a module holds what it provides, the composition
/// root can build the graph rather than a container factory building it at
/// `freeze()`.
struct GraphRoots {
    var emitted = false
    var needsConfiguration = false
    /// (label, type as written), in initializer order.
    var supplied: [(label: String, type: String)] = []
    /// Extra parameters of `flightRoutes(_:…)` — values only a controller
    /// needs, deliberately kept out of the graph.
    var terminalSupplied: [(label: String, type: String)] = []
}
var graphRoots = GraphRoots()

/// True when this target emitted `flightRoutes(_:)` — its own controllers'
/// routes, as a value. The composer folds it into the `[RouteRegistration]`
/// aggregate alongside whatever routes modules declare.
var emittedRouteValues = false

/// True when this target emitted `flightScheduledJobs(_:)`.
var emittedScheduledJobValues = false

// MARK: - FlightGraph (§2.1, emitted unused)
//
// The composition function, in the shape it will eventually replace
// `flightRegisterAll` with: every scanned component built once, in dependency
// order, by plain initializer calls. Nothing calls it yet — it is emitted so
// the shape can be read, compiled and diffed against the registration path
// before anything depends on it.
//
// What it can build is the application's own graph. A dependency it cannot
// construct — a framework component registered imperatively by a module
// (§2.11a), a type marked `flight:hand-registered`, anything the scan never
// saw — becomes an initializer parameter instead. That is §2.6's escape
// hatch: externally supplied values arrive through the same typed parameters
// everything else uses, visible at one root rather than scattered across N
// `configure(_:)` bodies.
@MainActor
func emitFlightGraph(into out: inout String) {
    // Module-registered types are excluded for the same reason
    // `flightRegisterAll` excludes them: whether they exist in an application
    // is a runtime question their own module answers.
    guard !graphRegistrable.isEmpty else { return }
    let registrable = graphRegistrable
    let nodes = graphNodes

    let byName = Dictionary(nodes.map { (baseName($0.typeName), $0) }, uniquingKeysWith: { a, _ in a })
    // One conformer per protocol, the same mapping the existential bridges
    // use — so `@Inject var store: (any RoomStore)` resolves to the concrete
    // type the graph already builds.
    var conformerOfProtocol: [String: ScannedComponent] = [:]
    for bridge in synthesizeBridges() {
        conformerOfProtocol[baseName(bridge.protocolName)] = bridge.component
    }

    func qualified(_ component: ScannedComponent) -> String {
        component.module == manifest.targetModuleName
            ? component.typeName
            : "\(component.module).\(component.typeName)"
    }
    func binding(_ component: ScannedComponent) -> String {
        let name = baseName(component.typeName)
        return name.prefix(1).lowercased() + name.dropFirst()
    }
    /// The node a dependency resolves to, or nil when the graph cannot build
    /// it and the root must supply it.
    func provider(of dependency: String) -> ScannedComponent? {
        if let direct = byName[baseName(dependency)] { return direct }
        if let name = existentialProtocolName(dependency) { return conformerOfProtocol[baseName(name)] }
        return nil
    }

    // Dependencies first, the order `freeze()` already constructs in.
    var ordered: [ScannedComponent] = []
    var finished: Set<String> = []
    var visiting: Set<String> = []
    func visit(_ component: ScannedComponent) {
        let key = baseName(component.typeName)
        if finished.contains(key) || visiting.contains(key) { return }
        visiting.insert(key)
        for dependency in component.injectTypeNames + component.acknowledgedTypeNames {
            if let next = provider(of: dependency) { visit(next) }
        }
        visiting.remove(key)
        finished.insert(key)
        ordered.append(component)
    }
    for node in nodes { visit(node) }

    // Externally supplied: every dependency with no node to build it, in a
    // stable order, deduplicated by the type as written.
    //
    // Over everything the generated code constructs, not just the graph's
    // own nodes: a controller is built by its route terminal rather than
    // held by the graph, and it reaches its dependencies *through* the
    // graph — so a root input only a controller needs still has to be
    // stored there.
    let terminalOnly = registrable.filter { component in
        !ordered.contains { baseName($0.typeName) == baseName(component.typeName) }
    }
    let constructed = ordered + terminalOnly

    /// Roots the **graph itself** needs — a dependency of a stored component
    /// that the graph cannot build.
    var supplied: [String] = []
    var seenSupplied: Set<String> = []
    for node in ordered {
        for dependency in node.dependencyOrder.map(\.type)
        where provider(of: dependency) == nil {
            if seenSupplied.insert(dependency).inserted { supplied.append(dependency) }
        }
    }

    /// Roots only a **route terminal** needs — a controller's dependency that
    /// no stored component shares.
    ///
    /// These are deliberately *not* graph properties, and the distinction is
    /// load-bearing rather than tidiness. A controller injecting
    /// `ChannelBroadcaster` used to make it a graph root, so the graph
    /// depended on `FlightChannelsModule` — and `FlightChannelsModule` takes
    /// the channel list, so nothing that builds channels from the graph could
    /// ever compose. A controller is not a component: it is constructed by its
    /// terminal, so what only it needs belongs to the terminal.
    var terminalSupplied: [String] = []
    for node in terminalOnly {
        for dependency in node.dependencyOrder.map(\.type)
        where provider(of: dependency) == nil && !seenSupplied.contains(dependency) {
            if !terminalSupplied.contains(dependency) { terminalSupplied.append(dependency) }
        }
    }
    func suppliedBinding(_ typeText: String) -> String {
        let name = baseName(existentialProtocolName(typeText) ?? typeText)
        return name.prefix(1).lowercased() + name.dropFirst()
    }

    let needsConfiguration = constructed.contains { !$0.configValues.isEmpty }

    // Published for `emitComposer`, which builds the graph from module
    // properties rather than leaving it to a container factory at freeze().
    graphRoots = GraphRoots(
        emitted: true,
        needsConfiguration: needsConfiguration,
        supplied: supplied.map { (label: suppliedBinding($0), type: $0) },
        terminalSupplied: terminalSupplied.map { (label: suppliedBinding($0), type: $0) })

    out += "\n"
    out += "/// Every component this module declares, constructed once, in\n"
    out += "/// dependency order, without a container.\n"
    out += "///\n"
    out += "/// The shape registration is becoming (COMPOSITION-MIGRATION.md\n"
    out += "/// §2.1). Route controllers are built from it per request; every\n"
    out += "/// other component is still registered, so both mechanisms are\n"
    out += "/// live and compiled together.\n"
    out += "///\n"
    out += "/// Internal, not public: an application's components are internal by\n"
    out += "/// default, and a public struct cannot expose them. The composition\n"
    out += "/// root is in this module too, so nothing needs it to be public.\n"
    out += "struct FlightGraph {\n"
    if needsConfiguration || !supplied.isEmpty {
        out += "    // Root inputs, stored: a route terminal reaches these the\n"
        out += "    // same way it reaches a component.\n"
    }
    if needsConfiguration {
        out += "    let configuration: FlightCore.Configuration\n"
    }
    for dependency in supplied {
        out += "    let \(suppliedBinding(dependency)): \(dependency)\n"
    }
    if (needsConfiguration || !supplied.isEmpty) && !ordered.isEmpty { out += "\n" }
    for node in ordered {
        out += "    let \(binding(node)): \(qualified(node))\n"
    }
    out += "\n"
    var parameters: [String] = []
    if needsConfiguration { parameters.append("configuration: FlightCore.Configuration") }
    parameters += supplied.map { "\(suppliedBinding($0)): \($0)" }
    // Every node is also a parameter, defaulting to nil, so a test can
    // replace one and get the rest of the graph real (§2.10). `nil` rather
    // than the composed value because a Swift default cannot reference
    // another parameter — the body does the `??`.
    parameters += ordered.map { "\(binding($0)): \(qualified($0))? = nil" }
    out += "    init(\(parameters.joined(separator: ", "))) throws {\n"
    if needsConfiguration { out += "        self.configuration = configuration\n" }
    for dependency in supplied {
        out += "        self.\(suppliedBinding(dependency)) = \(suppliedBinding(dependency))\n"
    }
    for node in ordered {
        var arguments: [String] = []
        if !node.configValues.isEmpty { arguments.append("_flightConfiguration: configuration") }
        // Labelled by property name, which is what the generated initializer
        // uses. Zipped rather than indexed: the two arrays are built together
        // and stay positional, and a mismatch would silently mislabel an
        // argument rather than fail.
        let edges = node.dependencyOrder
        for (dependency, label) in edges {
            if let source = provider(of: dependency) {
                arguments.append("\(label): \(binding(source))")
            } else {
                arguments.append("\(label): \(suppliedBinding(dependency))")
            }
        }
        let call = "\(qualified(node))(\(arguments.joined(separator: ", ")))"
        // Bound locally first: a later node's arguments must see the
        // *supplied* instance when a test passed one, not a second copy.
        out +=
            "        let \(binding(node)) = \(binding(node)) ?? \(node.configValues.isEmpty ? "" : "(try ")\(call)\(node.configValues.isEmpty ? "" : ")")\n"
        out += "        self.\(binding(node)) = \(binding(node))\n"
    }
    out += "    }\n"

    out += "}\n"

    // A named way to build it from a container, so the graph is
    // *constructible* and not merely compilable. Its root parameters are
    // exactly the things a module registers, and they resolve at freeze like
    // anything else.
    //
    // Emitted as a function rather than a registration, deliberately: every
    // component is built eagerly at freeze, so registering the graph would
    // make a missing root parameter fail the boot of an application that
    // works today — for a value nothing calls yet. A function is inert until
    // something calls it, and gives step 6 a single place to change.
    out += "\n"
    out += "/// Builds ``FlightGraph`` from a frozen container.\n"
    out += "///\n"
    out += "/// The bridge between the two wiring mechanisms while both exist:\n"
    out += "/// the graph's root parameters are the components modules register,\n"
    out += "/// so they resolve exactly as they always have.\n"
    out += "func makeFlightGraph(_ container: FlightCore.Container) throws -> FlightGraph {\n"
    var resolved: [String] = []
    if needsConfiguration {
        resolved.append("configuration: container.resolve(FlightCore.Configuration.self)")
    }
    for dependency in supplied {
        let metatype =
            dependency.hasPrefix("(") || !dependency.contains(" ")
            ? dependency : "(\(dependency))"
        resolved.append("\(suppliedBinding(dependency)): container.resolve(\(metatype).self)")
    }
    if resolved.isEmpty {
        out += "    try FlightGraph()\n"
    } else {
        out += "    try FlightGraph(\n"
        out += resolved.map { "        \($0)" }.joined(separator: ",\n") + "\n"
        out += "    )\n"
    }
    out += "}\n"

    // Route registrations with a per-request controller (§2.1a).
    //
    // The whole route lives in the factory `@Controller` generated; all this
    // supplies is *how the controller is obtained*. That closure is the
    // difference between the two wiring mechanisms: `_flightRegister` passes
    // one returning an instance the container resolved once, and this passes
    // one that constructs from the graph on every request.
    //
    // Emitted but not called, like the graph above. Calling it as well as
    // `flightRegisterAll` would register each route twice and fail the freeze
    // on a duplicate; the flip is one deletion in the macro, and it is the
    // last step because it is the one that changes behaviour.
    guard !routes.isEmpty else { return }
    let componentsByName = Dictionary(
        registrable.map { (baseName($0.typeName), $0) }, uniquingKeysWith: { a, _ in a })

    out += "\n"
    out += "/// Every route this target declares, with its controller\n"
    out += "/// constructed per request from ``FlightGraph`` rather than\n"
    out += "/// resolved once.\n"
    out += "///\n"
    out += "/// A value, handed to `FlightWebModule` by the composition root\n"
    out += "/// alongside whatever routes other modules declare. Controllers\n"
    out += "/// still register themselves for introspection, with\n"
    out += "/// `includingRoutes: false`, so the two do not both contribute the\n"
    out += "/// same route.\n"
    emittedRouteValues = true
    if !terminalSupplied.isEmpty {
        out += "///\n"
        out += "/// The extra parameters are values only a *controller* needs —\n"
        out += "/// no stored component shares them, so they are not graph\n"
        out += "/// properties. Keeping them here is what lets a module provide\n"
        out += "/// one *and* be built from the graph.\n"
    }
    let terminalParameters =
        terminalSupplied.map { ", \(suppliedBinding($0)): \($0)" }.joined()
    out += "func flightRoutes(_ graph: FlightGraph\(terminalParameters))\n"
    out += "    -> [FlightWeb.RouteRegistration]\n"
    out += "{\n"
    out += "    [\n"
    for route in routes {
        guard let controller = componentsByName[baseName(route.controllerTypeName)] else { continue }
        let type = qualified(controller)
        var arguments: [String] = []
        if !controller.configValues.isEmpty {
            arguments.append("_flightConfiguration: graph.configuration")
        }
        let edges = controller.dependencyOrder
        for (dependency, label) in edges {
            if let source = provider(of: dependency) {
                arguments.append("\(label): graph.\(binding(source))")
            } else if terminalSupplied.contains(dependency) {
                arguments.append("\(label): \(suppliedBinding(dependency))")
            } else {
                arguments.append("\(label): graph.\(suppliedBinding(dependency))")
            }
        }
        let construction =
            "\(controller.configValues.isEmpty ? "" : "try ")\(type)(\(arguments.joined(separator: ", ")))"
        let factory = "_flightRoute_\(route.methodName)_\(route.indexInController)"
        out += "        \(type).\(factory) { _ in \(construction) },\n"
    }
    out += "    ]\n"
    out += "}\n"

    // Scheduled jobs, the same way: the macro generated a value form beside
    // its registration form, and this closes it over the component the graph
    // built rather than one a container resolves when the job fires.
    let schedulers = ordered.filter { $0.attributeName == "Scheduler" }
    guard !schedulers.isEmpty else { return }
    emittedScheduledJobValues = true
    out += "\n"
    out += "/// Every scheduled job this target declares, bound to the\n"
    out += "/// components ``FlightGraph`` already built.\n"
    out += "func flightScheduledJobs(_ graph: FlightGraph)\n"
    out += "    -> [FlightScheduler.ScheduledJobRegistration]\n"
    out += "{\n"
    for scheduler in schedulers {
        out +=
            "    \(qualified(scheduler))._flightScheduledJobs { graph.\(binding(scheduler)) }\n"
        out += "        + \n"
    }
    out = String(out.dropLast("        + \n".count)) + "}\n"
}

// MARK: - The composition root
//
// Every module this application includes, constructed in dependency order and
// handed to `Flight.run(configuration:modules:composedBy:)`.
//
// `modules:` stays the declaration — the list of subsystems, written by the
// author and read by this generator — and this is what that list *means*
// once a module can take what it needs. Without a composer, Flight
// instantiates each module from its type, so a module must be constructible
// with no arguments and therefore reads configuration through the container;
// with one, a module declares its inputs and holds what it provides
// (COMPOSITION-MIGRATION.md D11).
//
// A module that still declares `init()` is called that way, so this works
// before any module moves and each conversion is one local change.
@MainActor
func emitComposer(into out: inout String) {
    guard !includedModules.isEmpty else { return }
    let byName = Dictionary(
        moduleGraph.map { (moduleKey($0.typeName), $0) }, uniquingKeysWith: { a, _ in a })

    func binding(_ text: String) -> String {
        let name = moduleKey(text)
        return name.prefix(1).lowercased() + name.dropFirst()
    }
    // Carried into the generated file as `#error`, rather than to stderr.
    // A composition that cannot be wired should fail the consumer's build with
    // the reason attached, at a line their compiler points at — not as a
    // warning scrolled past on the way to a confusing type error.
    var compositionDiagnostics: [String] = []
    /// Where a parameter's value comes from: another module, or a property of
    /// one. This is how one module's output becomes another's input, and
    /// neither module names the other — the type is the whole connection.
    ///
    /// Two shapes, tried in that order. A parameter whose type *is* a module
    /// takes that module. Otherwise the parameter is matched against the
    /// public stored properties of every included module, which is what
    /// carries `FlightPubSubValkeyModule.adapter` into
    /// `FlightPubSubModule(configuration:adapter:)`.
    ///
    /// `consumer` is excluded from both searches: a module cannot be built out
    /// of itself. Without that, `ActuatorModule`'s `init(environment:)` looks
    /// satisfiable by `ActuatorModule.environment` and the composer emits
    /// `let actuatorModule = ActuatorModule(environment: actuatorModule.environment)`.
    /// Every module contributing to an aggregate parameter, in module order.
    ///
    /// An aggregate is a parameter typed `[T]`, and it is the one place where
    /// several providers are right rather than ambiguous: channels, routes,
    /// scheduled jobs. Each is a *contribution*, and the aggregator wants all
    /// of them.
    ///
    /// This is what keeps the extension surface open. A module in a package
    /// flight has never heard of exposes `let channels: [ChannelRegistration]`
    /// and is wired in without the application enumerating it — the same
    /// openness `container.registerChannel` gave, without the container and
    /// without the post-`freeze()` collection that made it a cycle.
    func contributors(to type: String, for consumer: String)
        -> [(expression: String, module: String)]
    {
        guard let element = arrayElementType(type) else { return [] }
        let wanted = providedTypeKey(element)
        var found: [(expression: String, module: String)] = []
        for name in includedModules where moduleKey(name) != moduleKey(consumer) {
            guard let module = byName[moduleKey(name)] else { continue }
            for property in module.provides {
                guard let provided = arrayElementType(property.type),
                      providedTypeKey(provided) == wanted
                else { continue }
                found.append(("\(binding(name)).\(property.name)", name))
            }
        }
        return found
    }

    func provider(of type: String, for consumer: String) -> (expression: String, module: String)? {
        let wanted = providedTypeKey(type)
        let candidates = includedModules.filter { moduleKey($0) != moduleKey(consumer) }
        if let module = candidates.first(where: { moduleKey($0) == wanted }) {
            return (binding(module), module)
        }
        var matches: [(expression: String, module: String)] = []
        for name in candidates {
            guard let module = byName[moduleKey(name)] else { continue }
            for property in module.provides where providedTypeKey(property.type) == wanted {
                matches.append(("\(binding(name)).\(property.name)", name))
            }
        }
        switch matches.count {
        case 0: return nil
        case 1: return matches[0]
        default:
            // Ambiguity is a composition error, not something to guess at: two
            // modules offering the same type means the application has to say
            // which. Reported, and left to fail the build at the call site.
            compositionDiagnostics.append(
                "Composition is ambiguous: "
                    + matches.map(\.expression).sorted().joined(separator: " and ")
                    + " both provide \(wanted). Remove one, or give the consuming module an "
                    + "initializer that names which it wants.")
            return nil
        }
    }

    out += "\n"
    out += "/// Every module this application includes, in dependency order.\n"
    out += "///\n"
    out += "/// Pass to `Flight.run(configuration:modules:composedBy:)`. The\n"
    out += "/// `modules:` list stays the declaration of *which* subsystems the\n"
    out += "/// application includes; this is how they are built.\n"
    out += "func flightComposeModules(_ configuration: FlightCore.Configuration) throws\n"
    out += "    -> [any FlightCore.FlightModule]\n"
    out += "{\n"
    /// The argument for one parameter, or nil when nothing can supply it.
    ///
    /// An optional parameter with no provider is *omittable* rather than
    /// unsatisfiable — `adapter: (any DistributedPubSubAdapter)?` means "not
    /// in this deployment", which is §2.6's mechanism (3).
    func argument(
        label: String, type: String, for consumer: String, needing needed: inout Set<String>
    ) -> String?? {
        if baseName(type) == "Configuration" { return "\(label): configuration" }
        // The graph is a value the composition root builds, not a module, so
        // it is not in `includedModules` — but a module can take it, and the
        // application's own module does.
        if graphRoots.emitted, providedTypeKey(type) == "FlightGraph" {
            needed.insert("FlightGraph")
            return "\(label): flightGraph"
        }
        // Aggregates first: `[T]` is a collection of contributions, not a
        // single value some one module provides.
        if let element = arrayElementType(type) {
            var expressions: [String] = []
            // This target's own controllers come first, so an application's
            // routes precede a framework module's in the table — the order
            // `flightRegisterAll` produced when they were registrations.
            if emittedRouteValues, providedTypeKey(element) == "RouteRegistration" {
                needed.insert("FlightGraph")
                // Values only a controller needs are passed here rather than
                // stored on the graph, so a module can provide one and still
                // be built from the graph.
                var callArguments = ["flightGraph"]
                for root in graphRoots.terminalSupplied {
                    if let source = provider(of: root.type, for: "flightRoutes") {
                        needed.insert(moduleKey(source.module))
                        callArguments.append("\(root.label): \(source.expression)")
                    } else {
                        callArguments.append(
                            "\(root.label): <#nothing provides \(root.type)#>")
                        compositionDiagnostics.append(
                            "A route terminal needs \(root.type), and no module in this "
                                + "application provides it. A module that owns it should expose "
                                + "it as a stored property.")
                    }
                }
                expressions.append("flightRoutes(\(callArguments.joined(separator: ", ")))")
            }
            if emittedScheduledJobValues, providedTypeKey(element) == "ScheduledJobRegistration" {
                needed.insert("FlightGraph")
                expressions.append("flightScheduledJobs(flightGraph)")
            }
            let sources = contributors(to: type, for: consumer)
            for source in sources { needed.insert(moduleKey(source.module)) }
            expressions += sources.map(\.expression)
            guard !expressions.isEmpty else { return String?.none }  // nobody contributed
            return "\(label): \(expressions.joined(separator: " + "))"
        }
        if let source = provider(of: type, for: consumer) {
            needed.insert(moduleKey(source.module))
            return "\(label): \(source.expression)"
        }
        if type.hasSuffix("?") { return String?.none }  // omittable
        return nil  // unsatisfiable
    }

    /// One module's construction, and which other modules it had to draw on.
    struct Construction {
        let name: String
        let statement: String
        let needs: Set<String>
        /// Kept so an unconsumed contribution can be spotted below.
        let arguments: [String]
    }

    var constructions: [Construction] = []

    // The graph, built here rather than by a container factory at freeze().
    //
    // Its roots are the components modules provide, so they are matched the
    // same way a module's initializer parameters are — which is the whole
    // reason a module now *holds* what it provides. Sorted with the modules
    // below, because it both needs them (its roots) and is needed by them
    // (the application's module registers from it).
    if graphRoots.emitted {
        var arguments: [String] = []
        var needs: Set<String> = []
        if graphRoots.needsConfiguration { arguments.append("configuration: configuration") }
        for root in graphRoots.supplied {
            if let source = provider(of: root.type, for: "FlightGraph") {
                needs.insert(moduleKey(source.module))
                arguments.append("\(root.label): \(source.expression)")
            } else {
                arguments.append("\(root.label): <#nothing provides \(root.type)#>")
                compositionDiagnostics.append(
                    "The component graph needs \(root.type), and no module in this application "
                        + "provides it. A module that owns it should expose it as a stored "
                        + "property, which is how the composition root finds it.")
            }
        }
        constructions.append(
            Construction(
                name: "FlightGraph",
                statement:
                    "    let flightGraph = try FlightGraph(\(arguments.joined(separator: ", ")))",
                needs: needs,
                arguments: arguments))
    }

    for name in includedModules {
        let module = byName[moduleKey(name)]
        // The initializer the composer can actually supply, preferring the
        // most specific. "First declared" picks a test seam; "prefer init()"
        // picks a tombstone on a module that cannot be built from its type.
        // What it can satisfy is the question that has one right answer.
        var arguments: [String] = []
        var satisfiable = false
        var canThrow = false
        var needs: Set<String> = []
        for candidate in (module?.initializers ?? [(labels: [], types: [], throws: false)])
            .sorted(by: { $0.labels.count > $1.labels.count })
        {
            var built: [String] = []
            var candidateNeeds: Set<String> = []
            var ok = true
            for (label, type) in zip(candidate.labels, candidate.types) {
                guard
                    let resolved = argument(
                        label: label, type: type, for: name, needing: &candidateNeeds)
                else { ok = false; break }
                if let resolved { built.append(resolved) }
            }
            if ok {
                arguments = built
                satisfiable = true
                canThrow = candidate.throws
                needs = candidateNeeds
                break
            }
        }
        if !satisfiable {
            // Emitting the call anyway makes it a compile error naming the
            // module, which beats silently omitting it from the application.
            arguments = ["<#no initializer this composer can supply#>"]
        }
        // `try` only where the initializer throws: an unnecessary one is a
        // warning in every consumer's build.
        constructions.append(
            Construction(
                name: name,
                statement:
                    "    let \(binding(name)) = \(canThrow ? "try " : "")\(name)(\(arguments.joined(separator: ", ")))",
                needs: needs,
                arguments: arguments))
    }

    // A provider has to be built before whoever draws on it, and that ordering
    // no longer comes from `dependencies`: inverting the PubSub adapter
    // direction means `FlightPubSubValkeyModule` is a dependency of
    // `FlightPubSubModule` that flight cannot declare, because flight does not
    // know flight-data exists. The value flow says it instead — B takes a
    // property of A, therefore A first — which is the real edge, and the one
    // `dependencies` was always an approximation of.
    //
    // A stable sort over the declared order, so a module needing nothing stays
    // exactly where the module graph put it.
    var ordered: [Construction] = []
    var placed: Set<String> = []
    var remaining = constructions
    while !remaining.isEmpty {
        guard
            let index = remaining.firstIndex(where: {
                $0.needs.isSubset(of: placed)
            })
        else {
            // A cycle: two modules each wanting something the other holds.
            // Emit the rest in declared order so the failure is Swift's
            // "used before initialized" at a named line, not a silent
            // reordering that happens to compile.
            compositionDiagnostics.append(
                "Modules "
                    + remaining.map(\.name).sorted().joined(separator: ", ")
                    + " form a composition cycle: each needs a value another holds. Break it by "
                    + "moving the shared value into a module both can take it from.")
            ordered.append(contentsOf: remaining)
            break
        }
        let next = remaining.remove(at: index)
        placed.insert(moduleKey(next.name))
        ordered.append(next)
    }

    // A contribution nobody collects is silent: the module declaring channels
    // composes fine, the application starts, and the first join finds no
    // route. That is the failure mode the PubSub inversion existed to remove,
    // so it must not reappear here. An aggregate is reported when some scanned
    // module *would* take it and is not in this application — which names the
    // module to add rather than merely observing that a property went unused.
    let consumed = Set(constructions.flatMap(\.arguments))
    for name in includedModules {
        guard let module = byName[moduleKey(name)] else { continue }
        for property in module.provides {
            guard let element = arrayElementType(property.type) else { continue }
            let expression = "\(binding(name)).\(property.name)"
            guard !consumed.contains(where: { $0.contains(expression) }) else { continue }
            let aggregators = moduleGraph.filter { candidate in
                !includedModules.contains { moduleKey($0) == moduleKey(candidate.typeName) }
                    && candidate.initializers.contains { initializer in
                        initializer.types.contains {
                            arrayElementType($0).map(providedTypeKey) == providedTypeKey(element)
                        }
                    }
            }
            guard !aggregators.isEmpty else { continue }
            compositionDiagnostics.append(
                "\(name).\(property.name) is declared but nothing in this application collects "
                    + "it. Add "
                    + aggregators.map(\.typeName).sorted().joined(separator: " or ")
                    + " to the modules: list.")
        }
    }

    for construction in ordered {
        out += construction.statement + "\n"
    }
    out += "    return [\n"
    for construction in ordered where construction.name != "FlightGraph" {
        out += "        \(binding(construction.name)),\n"
    }
    out += "    ]\n"
    out += "}\n"
    for diagnostic in compositionDiagnostics {
        out += "#error(\"\(diagnostic.replacingOccurrences(of: "\"", with: "'"))\")\n"
    }
}

// MARK: - Static route manifest
//
// Every route this target declares, scanned at build time through the same
// `FlightRouteScan` parser `@Controller` expands with. Nothing consumes it
// yet: dispatch still collects `RouteRegistration` components out of the
// container (COMPOSITION-MIGRATION.md §2.9, work plan step 1). It is emitted
// now so the manifest and the container's route table can be compared on
// real applications before anything depends on the manifest being right.
//
// Emitted only when the target actually declares routes, so a target with no
// controllers gets a generated file of exactly the shape it had before.
// The manifest exists when the target has any Flight surface at all. A
// components-only target — a library of `@Service` types with no routes —
// gets one too, since the component list is the part a composition function
// is built from.
if !routes.isEmpty || !lanes.isEmpty || !moduleGraph.isEmpty || !mounts.isEmpty
    || !components.isEmpty
{
    let sorted = routes.sorted {
        ($0.path, $0.httpMethod, $0.source) < ($1.path, $1.httpMethod, $1.source)
    }
    out += "\n"
    out += "/// Every route this module declares, as scanned at build time.\n"
    out += "///\n"
    out += "/// Not yet consumed by dispatch — the route table is still built from\n"
    out += "/// `RouteRegistration` components. This is the static form it moves to.\n"
    out += "public enum FlightRouteManifest {\n"
    out += "    public struct Entry: Sendable {\n"
    out += "        public let method: String\n"
    out += "        public let path: String\n"
    out += "        public let source: String\n"
    out += "        /// Lane names as written, after the route-replaces-controller\n"
    out += "        /// rule; nil means the route inherits the default lane.\n"
    out += "        public let pipelines: String?\n"
    out += "        public let isUpgrade: Bool\n"
    out += "    }\n"
    out += "\n"
    out += "    public static let routes: [Entry] = [\n"
    for route in sorted {
        let pipelines = route.pipelinesText.map { "\"\(escaped($0))\"" } ?? "nil"
        out += "        Entry("
        out += "method: \"\(route.httpMethod)\", "
        out += "path: \"\(escaped(route.path))\", "
        out += "source: \"\(escaped(route.source))\", "
        out += "pipelines: \(pipelines), "
        out += "isUpgrade: \(route.isUpgrade)),\n"
    }
    out += "    ]\n"

    // Lanes, in declaration order. Order is the whole content of a lane
    // declaration — `pipeline` composes across calls, so a framework module
    // contributing `Authentication` and an application appending its own
    // concatenate by registration sequence, and flattening that here would
    // lose the only thing the declaration carries.
    out += "\n"
    out += "    /// One `container.pipeline(_:_:)` declaration, in the order\n"
    out += "    /// the scan met it. Calls compose: two declarations naming\n"
    out += "    /// one lane concatenate rather than conflict.\n"
    out += "    public struct Lane: Sendable {\n"
    out += "        /// nil when the lane argument is not a literal or a\n"
    out += "        /// canonical member — a computed name, unknowable here.\n"
    out += "        public let name: String?\n"
    out += "        /// Middleware type names, outermost first.\n"
    out += "        public let middleware: [String]\n"
    out += "        /// The type whose body declared it — nearly always a\n"
    out += "        /// FlightModule, and the reason this lane may or may not\n"
    out += "        /// exist in a given application.\n"
    out += "        public let declaredIn: String?\n"
    out += "        public let module: String\n"
    out += "    }\n"
    out += "\n"
    out += "    public static let lanes: [Lane] = [\n"
    for lane in lanesInModuleOrder() {
        let name = lane.lane.map { "\"\(escaped($0))\"" } ?? "nil"
        let declaredIn = lane.declaredIn.map { "\"\(escaped($0))\"" } ?? "nil"
        let middleware = lane.middleware.map { "\"\(escaped($0))\"" }.joined(separator: ", ")
        out += "        Lane("
        out += "name: \(name), "
        out += "middleware: [\(middleware)], "
        out += "declaredIn: \(declaredIn), "
        out += "module: \"\(escaped(lane.module))\"),\n"
    }
    out += "    ]\n"

    // The edges the lane order above was derived from, so a consumer holding
    // the real bootstrap list can redo the sort with the right roots. This
    // scan uses every scanned module as a root, in scan order, which
    // reproduces the runtime wherever a dependency path exists between two
    // modules and cannot where none does.
    out += "\n"
    out += "    /// A `FlightModule` conformer and the modules it pulls in.\n"
    out += "    public struct ModuleEdge: Sendable {\n"
    out += "        public let name: String\n"
    out += "        /// Dependency type names, generic arguments stripped.\n"
    out += "        public let dependencies: [String]\n"
    out += "        public let module: String\n"
    out += "    }\n"
    out += "\n"
    out += "    /// The modules this application includes: the ones its\n"
    out += "    /// bootstrap list names, plus everything those pull in\n"
    out += "    /// through `dependencies`, dependencies first.\n"
    out += "    ///\n"
    out += "    /// Empty for a target that starts nothing, which is what a\n"
    out += "    /// library is.\n"
    out += "    public static let includedModules: [String] = [\n"
    for module in includedModules {
        out += "        \"\(escaped(module))\",\n"
    }
    out += "    ]\n"
    out += "\n"
    out += "    public static let moduleGraph: [ModuleEdge] = [\n"
    for edge in moduleGraph.sorted(by: { $0.typeName < $1.typeName }) {
        let dependencies = edge.dependencies.map { "\"\(escaped($0))\"" }.joined(separator: ", ")
        out += "        ModuleEdge("
        out += "name: \"\(escaped(edge.typeName))\", "
        out += "dependencies: [\(dependencies)], "
        out += "module: \"\(escaped(edge.module))\"),\n"
    }
    out += "    ]\n"

    // Mounts, and the routes the scan could not see. Both are emitted even
    // when empty: "this application hand-registers nothing" is a fact worth
    // being able to read, and the whole point of the acknowledgment is that
    // a skipped route leaves a trace.
    out += "\n"
    out += "    /// A route family mounted by a framework convenience.\n"
    out += "    ///\n"
    out += "    /// The call site carries the prefix the framework derives its\n"
    out += "    /// routes from, so the mount is scannable even though the\n"
    out += "    /// `registerRoute` calls inside the convenience are not.\n"
    out += "    public struct Mount: Sendable {\n"
    out += "        /// \"assets\", \"uploads\", or \"socket\".\n"
    out += "        public let kind: String\n"
    out += "        /// nil when the prefix is interpolated or computed.\n"
    out += "        public let path: String?\n"
    out += "        public let pipelines: String?\n"
    out += "        public let declaredIn: String?\n"
    out += "        public let module: String\n"
    out += "    }\n"
    out += "\n"
    out += "    public static let mounts: [Mount] = [\n"
    for mount in mounts.filter({ $0.kind != .route }) {
        let path = mount.path.map { "\"\(escaped($0))\"" } ?? "nil"
        let pipelines = mount.pipelinesText.map { "\"\(escaped($0))\"" } ?? "nil"
        let declaredIn = mount.declaredIn.map { "\"\(escaped($0))\"" } ?? "nil"
        out += "        Mount("
        out += "kind: \"\(mount.kind.rawValue)\", "
        out += "path: \(path), "
        out += "pipelines: \(pipelines), "
        out += "declaredIn: \(declaredIn), "
        out += "module: \"\(escaped(mount.module))\"),\n"
    }
    out += "    ]\n"

    out += "\n"
    out += "    /// Routes registered by hand, which this manifest does not\n"
    out += "    /// carry. Named so a route the scan cannot see still leaves a\n"
    out += "    /// trace — the reason `registerRoute` asks for a\n"
    out += "    /// `flight:hand-registered` acknowledgment.\n"
    out += "    public struct HandRegistered: Sendable {\n"
    out += "        /// nil when the path is interpolated or computed.\n"
    out += "        public let path: String?\n"
    out += "        public let declaredIn: String?\n"
    out += "        public let module: String\n"
    out += "        public let file: String\n"
    out += "        public let line: Int\n"
    out += "    }\n"
    out += "\n"
    out += "    public static let handRegisteredRoutes: [HandRegistered] = [\n"
    for mount in mounts.filter({ $0.kind == .route }) {
        let path = mount.path.map { "\"\(escaped($0))\"" } ?? "nil"
        let declaredIn = mount.declaredIn.map { "\"\(escaped($0))\"" } ?? "nil"
        out += "        HandRegistered("
        out += "path: \(path), "
        out += "declaredIn: \(declaredIn), "
        out += "module: \"\(escaped(mount.module))\", "
        // Basename, not the absolute path the scan carries: this string is
        // baked into generated source, and an absolute path would make the
        // output differ between machines for no gain — the module name plus
        // the file name already locates it.
        let fileName = mount.file.split(separator: "/").last.map(String.init) ?? mount.file
        out += "file: \"\(escaped(fileName))\", "
        out += "line: \(mount.line)),\n"
    }
    out += "    ]\n"

    // The component list. What `allRegistrations()` answers at runtime, known
    // before the binary exists — and, unlike the runtime's answer, carrying
    // the dependency edges, which is what a composition function is built
    // from (COMPOSITION-MIGRATION.md §2.1).
    out += "\n"
    out += "    /// A registrable component, as scanned.\n"
    out += "    public struct Component: Sendable {\n"
    out += "        /// Qualified with its module when it comes from another\n"
    out += "        /// one, matching how registration names it.\n"
    out += "        public let typeName: String\n"
    out += "        /// \"service\", \"repository\", \"controller\", …\n"
    out += "        public let stereotype: String\n"
    out += "        /// Source text of the `scope:` argument.\n"
    out += "        public let scope: String\n"
    out += "        public let qualifier: String?\n"
    out += "        /// `@Inject` types, in declaration order — the edges a\n"
    out += "        /// composition function orders construction by.\n"
    out += "        public let dependencies: [String]\n"
    out += "        /// Registered by its own module rather than by\n"
    out += "        /// `flightRegisterAll`, because whether it exists in an\n"
    out += "        /// application is a runtime question.\n"
    out += "        public let isModuleRegistered: Bool\n"
    out += "        public let module: String\n"
    out += "    }\n"
    out += "\n"
    out += "    public static let components: [Component] = [\n"
    for component in components.sorted(by: { ($0.module, $0.typeName) < ($1.module, $1.typeName) }) {
        let qualified =
            component.module == manifest.targetModuleName
            ? component.typeName
            : "\(component.module).\(component.typeName)"
        let qualifier = component.qualifierText.map { "\"\(escaped($0))\"" } ?? "nil"
        // Acknowledged edges are dependencies too — the marker says the type
        // is registered by hand, not that nothing depends on it.
        let dependencies = (component.injectTypeNames + component.acknowledgedTypeNames)
            .map { "\"\(escaped($0))\"" }.joined(separator: ", ")
        out += "        Component("
        out += "typeName: \"\(escaped(qualified))\", "
        out += "stereotype: \"\(stereotype(forAttribute: component.attributeName))\", "
        out += "scope: \"\(escaped(component.scopeText))\", "
        out += "qualifier: \(qualifier), "
        out += "dependencies: [\(dependencies)], "
        out += "isModuleRegistered: \(component.isModuleRegistered), "
        out += "module: \"\(escaped(component.module))\"),\n"
    }
    out += "    ]\n"
    out += "}\n"
}

emitFlightGraph(into: &out)
emitComposer(into: &out)

do {
    let outputURL = URL(fileURLWithPath: manifest.output)
    try FileManager.default.createDirectory(
        at: outputURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try out.write(to: outputURL, atomically: true, encoding: .utf8)
} catch {
    FileHandle.standardError.write(
        "flight-registration-gen: cannot write output: \(error)\n".data(using: .utf8)!)
    exit(2)
}
