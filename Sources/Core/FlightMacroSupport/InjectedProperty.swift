import SwiftSyntax
import SwiftSyntaxBuilder

/// One `@Inject` or `@ConfigValue` property, as every registration macro sees
/// it.
///
/// Shared because it was written three times — identically, each copy
/// carrying a comment saying it mirrored the others. `@Component`,
/// `@Controller` and `@Middleware` all expand to the same shape, so the
/// property model, the parenthesisation rule and the initializers generated
/// from them belong in one place. The collection functions stay per-macro:
/// they differ in the diagnostics they emit, which is the part that should
/// name the attribute the author actually wrote.
public struct InjectedProperty {
    public enum Kind {
        case inject(qualifier: String?)
        /// `defaultValue` is the `default:` argument's source text,
        /// re-embedded verbatim in the expansion (nil = required key).
        case configValue(key: String, defaultValue: String?)
    }

    public let name: String
    public let typeText: String
    public let kind: Kind
    /// The declaration, for diagnostics.
    public let node: VariableDeclSyntax

    public init(name: String, typeText: String, kind: Kind, node: VariableDeclSyntax) {
        self.name = name
        self.typeText = typeText
        self.kind = kind
        self.node = node
    }

    /// The type as written, parenthesized where `.self` would otherwise bind
    /// to the wrong thing.
    ///
    /// `any P.self` parses as `any (P.self)`, so the expansion for
    /// `@Inject var bus: any PubSub` — the spelling every doc page uses —
    /// failed with "'self' is not a member type of protocol PubSub",
    /// reported inside the macro expansion rather than at the property.
    public var metatypeBase: String {
        if typeText.hasPrefix("(") && typeText.hasSuffix(")") { return typeText }
        if typeText.hasPrefix("any ") || typeText.hasPrefix("some ") || typeText.contains(" & ") {
            return "(\(typeText))"
        }
        return typeText
    }

    public var isInjected: Bool {
        if case .inject = kind { return true }
        return false
    }
}

/// The parameter-label lists of every initializer the type declares itself.
///
/// Used to skip generating one that would redeclare a hand-written init — a
/// redeclaration error reported inside an expansion the author cannot see.
public func declaredInitializerLabels(_ declaration: some DeclGroupSyntax) -> [[String]] {
    declaration.memberBlock.members.compactMap { member in
        guard let initializer = member.decl.as(InitializerDeclSyntax.self) else { return nil }
        return initializer.signature.parameterClause.parameters.map {
            $0.firstName.tokenKind == .wildcard ? "_" : $0.firstName.text
        }
    }
}

/// Constructor injection: the same properties, as parameters.
///
/// This is what a composition function calls and what a test calls —
/// `UserService(repo: FakeRepo())`, with no container, no registration and no
/// override registry. A struct would get it from memberwise synthesis, except
/// that the generated `init(_flight:)` suppresses that, which is why it has
/// to be generated rather than relied on.
///
/// `@ConfigValue` properties stay derived rather than becoming parameters:
/// their value is a property of the deployment, not of the call site, and a
/// caller passing one would be overriding configuration by accident. The
/// configuration itself is the parameter, and only when the type reads from
/// it.
///
/// Returns nil when the type already declares an initializer with the same
/// labels — `Authentication` is the live case, carrying an `@Inject` property
/// *and* a hand-written `init(validator:)` for manual wiring.
public func parameterizedInitializer(
    properties: [InjectedProperty],
    access: String,
    declaration: some DeclGroupSyntax
) -> DeclSyntax? {
    let injected = properties.filter(\.isInjected)
    let configured = properties.filter { !$0.isInjected }

    var parameters = injected.map { "\($0.name): \($0.typeText)" }
    var labels = injected.map(\.name)
    if !configured.isEmpty {
        parameters.insert("_flightConfiguration configuration: FlightCore.Configuration", at: 0)
        labels.insert("_flightConfiguration", at: 0)
    }
    guard !declaredInitializerLabels(declaration).contains(labels) else { return nil }

    var assignments = injected.map { "self.\($0.name) = \($0.name)" }
    for property in configured {
        guard case .configValue(let key, let defaultValue) = property.kind else { continue }
        if let defaultValue {
            assignments.append(
                "self.\(property.name) = try configuration.getIfPresent(\(key), as: \(property.metatypeBase).self) ?? (\(defaultValue))"
            )
        } else {
            assignments.append(
                "self.\(property.name) = try configuration.get(\(key), as: \(property.metatypeBase).self)"
            )
        }
    }
    let body = assignments.isEmpty ? "" : "\n    " + assignments.joined(separator: "\n    ") + "\n"
    let throwsClause = configured.isEmpty ? "" : " throws"
    return """
        \(raw: access)init(\(raw: parameters.joined(separator: ", ")))\(raw: throwsClause) {\(raw: body)}
        """
}
