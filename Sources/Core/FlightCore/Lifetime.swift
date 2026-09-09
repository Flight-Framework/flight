/// Component lifetimes. Singleton is the only one — see <doc:Lifetimes>.
public enum Lifetime: Sendable, Equatable {
    /// One instance for the application's lifetime, built once by the
    /// composition root, in dependency order.
    case singleton
}

/// Errors thrown by dynamic resolution paths. The macro-generated
/// path should never hit these at runtime in a correctly building app — they
/// are the fallback for genuinely dynamic resolution.
public enum ResolutionError: Error, CustomStringConvertible, Sendable {
    case notRegistered(String)
    case circularDependency([String])
    /// A registration's factory produced a value that failed the cast back to
    /// the requested type. Unreachable through the public generic `register`;
    /// kept as a named failure rather than a trap for defense in depth.
    case typeMismatch(requested: String, produced: String)

    public var description: String {
        switch self {
        case .notRegistered(let name):
            return
                "No component available for \(name). If this type is annotated @Component, the build plugin may not be wired into this target; if it is provided by a module, check that the module is composed in."
        case .circularDependency(let chain):
            return "Circular dependency: \(chain.joined(separator: " → "))"
        case .typeMismatch(let requested, let produced):
            return "Factory for \(requested) produced \(produced)."
        }
    }
}

/// A component's architectural layer. Stereotype macros expand *identically*
/// to `@Component`, differing only in this tag. It is not cosmetic: Actuator
/// groups its dashboard by layer, and it is the pointcut for any future
/// default AOP policy ("all @Repository methods join the ambient
/// transaction"). Not part of component identity — construction never consults
/// it; it rides the build-scanned descriptor.
public enum Stereotype: Sendable, Equatable, CaseIterable {
    /// Generic registration (`@Component`), incl. third-party client wrappers.
    case component
    /// Business logic (`@Service`).
    case service
    /// Data access (`@Repository`).
    case repository
    /// HTTP entry points. The `@Controller` *macro* lives in Flight Web (it
    /// carries route metadata meaningless outside HTTP dispatch); the case
    /// lives here so the introspection vocabulary stays Web-free.
    case controller
    /// A `@Settings` type — configuration bound to a typed value at
    /// bootstrap, once, validated. Actuator lists these separately from
    /// ordinary components: "what is this app's configuration, as resolved"
    /// is a different question from "what is this app made of", and deserves
    /// its own answer.
    case settings
    /// A `@Middleware` type. The `@Middleware` *macro* lives in Flight Web,
    /// same reason `@Controller`'s does; the case lives here for the same
    /// reason `.controller`'s does.
    case middleware
}

/// Introspection metadata. Captured explicitly at registration time —
/// Swift has no runtime reflection to lean on, and doesn't need it here.
public struct ComponentDescriptor: Sendable, Equatable {
    public let typeName: String
    public let scope: Lifetime
    /// Which FlightModule registered this (stamped by bootstrap around each
    /// module's `configure` call). "<direct>" for registrations made outside
    /// module configuration (tests, ad-hoc wiring).
    public let sourceModule: String
    /// Additive relative to the spec doc's three fields: qualifiers are part
    /// of a component's identity, so the Actuator dashboard needs
    /// them to render duplicate-type registrations distinguishably.
    public let qualifier: String?
    /// The component's layer — how Actuator groups the dashboard.
    public let stereotype: Stereotype

    /// Public because the *generated* component list constructs these: the
    /// build knows what it scanned, and Actuator renders that rather than
    /// asking the container what it holds.
    public init(
        typeName: String,
        scope: Lifetime,
        sourceModule: String,
        qualifier: String?,
        stereotype: Stereotype
    ) {
        self.typeName = typeName
        self.scope = scope
        self.sourceModule = sourceModule
        self.qualifier = qualifier
        self.stereotype = stereotype
    }
}
