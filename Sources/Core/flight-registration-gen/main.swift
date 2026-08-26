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
// synthesized *existential bridges*: for every `@Autowired var x: (any P)`
// demand whose protocol has exactly one scanned conformer, a registration of
// the existential key routing to that conformer (see the synthesis section
// below for the exact rules and escape hatches).
//
// Diagnostics are printed to stderr in `path:line:col: severity: message`
// form, which SwiftPM surfaces in build logs and IDEs.

import FlightConfigCore
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
    let autowiredTypeNames: [String]
    /// `@Autowired` types whose property carries a `flight:hand-registered`
    /// marker comment — the author's acknowledgment that the type is
    /// registered by hand in a module's `configure(_:)` (invisible to this
    /// scanner, P-2) and the missing-registration warning should not fire.
    /// Still participates in cycle detection.
    let acknowledgedTypeNames: [String]
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
            inheritanceClause: node.inheritanceClause, position: node.position)
        return .skipChildren
    }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        collect(
            name: node.name.text, attributes: node.attributes,
            modifiers: node.modifiers, members: node.memberBlock,
            inheritanceClause: node.inheritanceClause, position: node.position)
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

    private func collect(
        name: String,
        attributes: AttributeListSyntax,
        modifiers: DeclModifierListSyntax,
        members: MemberBlockSyntax,
        inheritanceClause: InheritanceClauseSyntax?,
        position: AbsolutePosition
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
        let isSettingsType =
            registrable.attributeName.as(IdentifierTypeSyntax.self)?.name.text == "Settings"
        let settingsNamespace = isSettingsType ? literalKey(of: registrable) : nil

        var autowired: [String] = []
        var acknowledged: [String] = []
        var configValues: [ScannedConfigValue] = []
        for member in members.members {
            guard let variable = member.decl.as(VariableDeclSyntax.self) else { continue }
            if hasAttribute(variable.attributes, named: "Autowired"),
                let type = variable.bindings.first?.typeAnnotation?.type.trimmedDescription
            {
                // `member.description` spans the member's leading trivia
                // through its last token's trailing trivia, so the marker is
                // found whether it sits on the line above the property or as
                // a same-line trailing comment.
                if member.description.contains("flight:hand-registered") {
                    acknowledged.append(type)
                } else {
                    autowired.append(type)
                }
            }
            if let attribute = attribute(of: variable.attributes, named: "ConfigValue") {
                let propertyLocation = converter.location(for: variable.position)
                configValues.append(
                    ScannedConfigValue(
                        key: literalKey(of: attribute),
                        hasDefault: hasLabeledArgument(attribute, label: "default"),
                        source: .explicitConfigValue,
                        file: file,
                        line: propertyLocation.line
                    ))
                continue
            }

            if let namespace = settingsNamespace,
                !hasAttribute(variable.attributes, named: "Autowired")
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
                isPublic: isPublic,
                scopeText: labeledArgumentSource(of: registrable, label: "scope") ?? ".singleton",
                qualifierText: labeledArgumentSource(of: registrable, label: "qualifier"),
                conformanceNames: inheritanceClause?.inheritedTypes.map {
                    $0.type.trimmedDescription
                } ?? [],
                autowiredTypeNames: autowired,
                acknowledgedTypeNames: acknowledged,
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
        else { continue }
        let tree = Parser.parse(source: source)
        let visitor = ComponentVisitor(module: module.name, file: file, tree: tree)
        visitor.walk(tree)
        components.append(contentsOf: visitor.components)
        extensionConformances.append(contentsOf: visitor.extensionConformances)
    }
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
// `@Autowired var x: (any P)` resolves the EXISTENTIAL key. Nothing used to
// populate that key, so every protocol seam cost a hand-written bridge in a
// module's configure(_:) plus a marker comment silencing the warning below.
// The scanner sees both sides of the seam — the demand in @Autowired type
// text, the supply in inheritance clauses and extensions — so when a demanded
// protocol has exactly one scanned conformer, the bridge is generated into
// flightRegisterAll instead.
//
// Demand-driven on purpose: binding only what some @Autowired actually asks
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
        for dependency in component.autowiredTypeNames {
            guard let name = existentialProtocolName(dependency) else { continue }
            let base = baseName(name)
            if demands[base] == nil { demands[base] = (name, component) }
        }
    }

    var bridges: [SynthesizedBridge] = []
    for base in demands.keys.sorted() {
        guard !suppressed.contains(base) else { continue }
        let demand = demands[base]!
        let conformers = components.filter { component in
            component.conformanceNames.contains { baseName($0) == base }
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
                "@Autowired type '(any \(demand.protocolName))' in \(demand.demandedBy.typeName) has \(conformers.count) scanned conformers (\(conformers.map(\.typeName).sorted().joined(separator: ", "))) — no bridge was generated. Register the existential by hand in a module's configure(_:) and acknowledge the property with a `// flight:hand-registered` comment.",
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
    for dependency in component.autowiredTypeNames {
        // Demands satisfied by a synthesized bridge are no longer suspicious.
        if let name = existentialProtocolName(dependency),
            bridgedProtocolBaseNames.contains(baseName(name))
        {
            continue
        }
        let base =
            dependency
            .replacingOccurrences(of: "?", with: "")
            .trimmingCharacters(in: .whitespaces)
        if !knownTypeNames.contains(base) && !alwaysAvailable.contains(base) {
            emit(
                "warning",
                "@Autowired type '\(base)' in \(component.typeName) is not a scanned @Component. If it is hand-registered in a module's configure(_:), acknowledge it with a `// flight:hand-registered` comment on the property; otherwise resolution will fail at startup.",
                file: component.file, line: component.line
            )
        }
    }
}

// Static cycle detection over the @Autowired edges (name-level, qualifier-blind).
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
        for dependency in (component.autowiredTypeNames + component.acknowledgedTypeNames)
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

// MARK: - Emission

// Deterministic output: sort by (module, type). Stable output means stable
// builds and readable diffs of the generated file.
let sorted = components.sorted {
    ($0.module, $0.typeName) < ($1.module, $1.typeName)
}
let dependencyModules = Set(sorted.map(\.module)).subtracting([manifest.targetModuleName]).sorted()

var out = """
    // AUTO-GENERATED by flight-registration-gen — do not edit.
    // Target: \(manifest.targetModuleName)
    // Components: \(sorted.count), existential bridges: \(bridges.count)

    import FlightCore

    """
for module in dependencyModules {
    out += "import \(module)\n"
}
out += """

    /// Registers every @Component visible from \(manifest.targetModuleName)
    /// (its own sources plus all Flight-based dependency modules). Call this
    /// from a FlightModule's configure(_:) or directly before freeze().
    public func flightRegisterAll(_ container: FlightCore.Container) throws {
    """
if sorted.isEmpty {
    out += "\n    // No @Component types found in scope.\n"
} else {
    out += "\n"
    for component in sorted {
        let qualified =
            component.module == manifest.targetModuleName
            ? component.typeName
            : "\(component.module).\(component.typeName)"
        out += "    try \(qualified)._flightRegister(container)\n"
    }
}
if !bridges.isEmpty {
    // Emitted line by line rather than as a multiline literal: a multiline
    // literal strips indentation relative to its CLOSING delimiter, so a
    // formatter that re-indents the block silently changes the emitted text.
    // These carry their indentation explicitly and cannot drift.
    out += "\n"
    out += "    // Existential bridges (demand-driven): each `@Autowired var _: (any P)`\n"
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
        // resolveInActiveScope for scoped conformers: by the time the bridge
        // factory runs, resolution of the scoped existential key has already
        // bound the ambient scope, and the explicit spelling keeps the
        // captive-dependency error precise. Everything else is a plain resolve.
        let resolveCall =
            component.scopeText.hasSuffix("scoped")
            ? "try c.resolveInActiveScope(\(concrete).self\(qualifierArgument))"
            : "try c.resolve(\(concrete).self\(qualifierArgument))"
        out +=
            "    container.register((any \(bridge.protocolName)).self, scope: \(component.scopeText)) { c in\n"
        out += "        \(resolveCall)\n"
        out += "    }\n"
    }
}
out += "}\n"

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
