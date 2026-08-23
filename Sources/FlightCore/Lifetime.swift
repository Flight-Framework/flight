/// Component lifetimes.
public enum Lifetime: Sendable, Equatable {
    /// One instance for the container's lifetime. Constructed eagerly at
    /// `freeze()` — see `FrozenStorage.singletons` for why.
    case singleton
    /// A new instance on every resolve.
    case transient
    /// One instance per `Scope`. Resolving a scoped component without an
    /// active scope throws `ResolutionError.scopeRequired`.
    case scoped
}

/// Errors thrown by dynamic resolution paths. The macro-generated
/// path should never hit these at runtime in a correctly building app — they
/// are the fallback for genuinely dynamic resolution.
public enum ResolutionError: Error, CustomStringConvertible, Sendable {
    case notRegistered(String)
    case circularDependency([String])
    case scopeRequired(String)
    /// `resolveInActiveScope` was called with no ambient scope bound
    /// — either from outside any scoped resolution, or from a
    /// singleton factory during `freeze()`'s eager construction (a captive
    /// dependency, caught loudly at startup).
    case noActiveScope(String)
    /// A registration's factory produced a value that failed the cast back to
    /// the requested type. Unreachable through the public generic `register`;
    /// kept as a named failure rather than a trap for defense in depth.
    case typeMismatch(requested: String, produced: String)

    public var description: String {
        switch self {
        case .notRegistered(let name):
            return
                "No component registered for \(name). If this type is annotated @Component, the build plugin's generated _registerAll may not be wired in; if it is hand-registered, check the qualifier."
        case .circularDependency(let chain):
            return "Circular dependency: \(chain.joined(separator: " → "))"
        case .scopeRequired(let name):
            return
                "\(name) is registered as .scoped; resolve it via resolve(_:in:) inside withScope { }."
        case .noActiveScope(let name):
            return
                "resolveInActiveScope(\(name)) found no ambient scope. It is only meaningful inside a factory running under resolve(_:in:); a singleton factory can never depend on a scoped component (captive dependency)."
        case .typeMismatch(let requested, let produced):
            return "Factory for \(requested) produced \(produced)."
        }
    }
}

/// A component's architectural layer. Stereotype macros expand
/// *identically* to `@Component` — same marker, same thunk — differing only
/// in this tag. It is not cosmetic: Actuator groups its dashboard by layer,
/// and it is the pointcut for any future default AOP policy ("all
/// @Repository methods join the ambient transaction"). Not part of component
/// identity — resolution never consults it.
public enum Stereotype: Sendable, Equatable {
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
}
