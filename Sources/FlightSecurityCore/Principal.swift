/// The authenticated identity.
///
/// A `Principal` is produced by a ``TokenValidator`` from an externally
/// issued identity token. `roles`, `scopes`, and `claims` are surfaced
/// directly from the validated token — Flight parses data it already has,
/// it does not build an identity model.
public struct Principal: Sendable {
    /// The IdP's stable user id (JWT `sub`).
    public let subject: String

    /// Which IdP asserted this identity (JWT `iss`).
    public let issuer: String

    /// Roles from the token's roles/groups claim(s).
    public let roles: Set<String>

    /// OAuth2 scopes, if present on the token.
    public let scopes: Set<String>

    /// Remaining claims, for application use. Values are the standard JSON
    /// bridges: `String`, `Int`, `Double`, `Bool`, `[any Sendable]`, and
    /// `[String: any Sendable]`. Claims whose value is JSON `null` are
    /// omitted.
    public let claims: [String: any Sendable]

    public init(
        subject: String,
        issuer: String,
        roles: Set<String> = [],
        scopes: Set<String> = [],
        claims: [String: any Sendable] = [:]
    ) {
        self.subject = subject
        self.issuer = issuer
        self.roles = roles
        self.scopes = scopes
        self.claims = claims
    }

    public func hasRole(_ role: String) -> Bool { roles.contains(role) }

    public func hasScope(_ scope: String) -> Bool { scopes.contains(scope) }

    /// Typed access to an application claim: `principal.claim("email", as: String.self)`.
    public func claim<T: Sendable>(_ name: String, as type: T.Type = T.self) -> T? {
        claims[name] as? T
    }
}

extension Principal {
    /// The ambient principal for the current task tree.
    ///
    /// Bound with `Principal.$current.withValue(...)`, most conveniently via
    /// `RequestContext.withPrincipal { ... }` inside a handler. The value
    /// propagates to structured child tasks (`async let`, task groups) but
    /// **not** across `Task.detached` boundaries — which is correct: a
    /// detached background job should not silently inherit the requester's
    /// identity.
    ///
    /// Note: because Flight Web middleware runs as a flat chain (each
    /// middleware returns before the next runs), the authentication
    /// middleware cannot bind this task-local around the handler for you.
    /// Inside handlers and middleware, read `context.principal`; use this
    /// task-local for services called under `withPrincipal`.
    @TaskLocal public static var current: Principal?
}
