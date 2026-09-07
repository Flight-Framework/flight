/// The identity a request carries, as the web layer needs to see it.
///
/// Flight Web never interprets this — it stores it, and authentication
/// middleware writes it. The seam is a protocol rather than a concrete type
/// because `RequestContext` lives here and `FlightSecurityCore.Principal`
/// lives in a package that depends on this one, so naming that type would be
/// a dependency cycle. That cycle is the real reason the principal used to
/// travel as a `.scoped` component resolved out of the container: the
/// container inverted a dependency the type system would not allow directly.
///
/// Exactly the shape `FlightChannels` already uses for the same problem —
/// `ChannelPrincipal` is a two-member seam owned by the package that needs to
/// read an identity, with no dependency on any particular identity
/// implementation. `FlightSecurityCore.Principal` conforms to both.
public protocol RequestPrincipal: Sendable {
    /// The stable identity — the IdP's opaque user id.
    var subject: String { get }

    func hasRole(_ role: String) -> Bool
}

extension RequestPrincipal {
    /// Roles are optional richness; a bare subject-only principal is valid.
    public func hasRole(_ role: String) -> Bool { false }
}

/// What authentication decided about this request.
///
/// Three states rather than an optional principal, because "no credential
/// was presented" and "a credential was presented and rejected" are
/// different facts and an enforcement point answers them differently — the
/// second earns an RFC 6750 `error="invalid_token"` challenge.
///
/// `.anonymous` carries no payload, so an unauthenticated request pays
/// nothing beyond the enum's own bytes when the context is copied.
public enum RequestIdentity: Sendable {
    /// No credential was presented.
    case anonymous
    /// A credential was presented and failed validation. The reason stays in
    /// the internal log — nothing token-specific reaches the wire.
    case invalidCredential
    /// A credential was presented and validated.
    case authenticated(any RequestPrincipal)

    public var principal: (any RequestPrincipal)? {
        if case .authenticated(let principal) = self { return principal }
        return nil
    }

    public var isAuthenticated: Bool {
        if case .authenticated = self { return true }
        return false
    }
}
