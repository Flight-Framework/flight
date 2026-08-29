import FlightCore
import Foundation

/// Configuration of the generic OIDC validator.
///
/// Switching providers is changing `issuer`/`audience` (and, rarely, an
/// explicit JWKS URL) — configuration, not a code or package change.
///
/// Flight Config keys (all under `security.oidc.`, overridable via
/// `FLIGHT_SECURITY_OIDC_*` environment variables):
///
/// | key                     | required | default                              |
/// |-------------------------|----------|--------------------------------------|
/// | `issuer`                | yes      | —                                    |
/// | `audience`              | yes      | —                                    |
/// | `jwks_url`              | no       | OIDC discovery from the issuer       |
/// | `jwks_cache_ttl`        | no       | 3600 (seconds)                       |
/// | `clock_skew_leeway`     | no       | 60 (seconds)                         |
/// | `jwks_refresh_cooldown` | no       | 30 (seconds)                         |
/// | `roles_claim`           | no       | `roles,groups,realm_access.roles`    |
/// | `scopes_claim`          | no       | `scope,scp`                          |
public struct OIDCSecurityConfiguration: Sendable {
    /// The IdP's issuer identifier; must equal the token's `iss` exactly.
    public var issuer: String

    /// This application's identifier; the token's `aud` must include it.
    public var audience: String

    /// Explicit JWKS endpoint. `nil` means resolve it once via OIDC
    /// discovery (`{issuer}/.well-known/openid-configuration`).
    public var jwksURL: URL?

    /// How long fetched keys stay fresh before a revalidating refetch.
    public var jwksCacheTTL: TimeInterval

    /// Leeway applied to `exp` and `nbf` (design: JWTKit supplies the
    /// primitive; Flight sets the policy).
    public var clockSkewLeeway: TimeInterval

    /// Minimum interval between JWKS fetch attempts, so unknown-`kid`
    /// refreshes and failing endpoints cannot be leveraged into hammering
    /// the IdP.
    public var jwksRefreshCooldown: TimeInterval

    /// How long a cached key set may keep being served while the IdP is
    /// unreachable, before validation starts failing instead.
    ///
    /// Unbounded stale-serving means a revoked key stays honored for the
    /// whole outage. Bounded, a long outage eventually costs availability
    /// rather than silently costing revocation.
    public var jwksMaxStaleAge: TimeInterval

    /// Whether key material may be fetched over plaintext HTTP.
    ///
    /// `https_only` by default, and there is no good reason to change it
    /// outside local development: whoever answers this fetch chooses the
    /// keys that verify every token this service accepts.
    public var jwksTransport: JWKSTransportPolicy

    /// Claim names searched (in union) for roles. Each entry is an exact
    /// claim name first, else a dot-path into nested objects — the default
    /// covers plain `roles`, `groups`, and Keycloak's `realm_access.roles`.
    public var rolesClaims: [String]

    /// Claim names searched (in union) for OAuth2 scopes. Space-delimited
    /// string claims (`scope`) are split; array claims (`scp`) are taken
    /// element-wise.
    public var scopesClaims: [String]

    /// The defaults, written once.
    ///
    /// The memberwise initialiser and the config parser each carried their
    /// own copy of every one of these, so a changed default was a two-place
    /// edit with nothing to catch the half that was missed — and the two
    /// halves disagreeing means a value that depends on which door the
    /// configuration came through.
    public enum Defaults {
        public static let jwksCacheTTL: TimeInterval = 3600
        public static let clockSkewLeeway: TimeInterval = 60
        public static let jwksRefreshCooldown: TimeInterval = 30
        public static let jwksMaxStaleAge: TimeInterval = 6 * 60 * 60
        public static let rolesClaims = ["roles", "groups", "realm_access.roles"]
        public static let scopesClaims = ["scope", "scp"]
    }

    public init(
        issuer: String,
        audience: String,
        jwksURL: URL? = nil,
        jwksCacheTTL: TimeInterval = Defaults.jwksCacheTTL,
        clockSkewLeeway: TimeInterval = Defaults.clockSkewLeeway,
        jwksRefreshCooldown: TimeInterval = Defaults.jwksRefreshCooldown,
        jwksMaxStaleAge: TimeInterval = Defaults.jwksMaxStaleAge,
        jwksTransport: JWKSTransportPolicy = .httpsOnly,
        rolesClaims: [String] = Defaults.rolesClaims,
        scopesClaims: [String] = Defaults.scopesClaims
    ) throws {
        guard !issuer.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ConfigError.decodingFailed(
                key: "security.oidc.issuer", rawValue: issuer, targetType: String(describing: OIDCSecurityConfiguration.self)
            )
        }
        guard !audience.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ConfigError.decodingFailed(
                key: "security.oidc.audience", rawValue: audience, targetType: String(describing: OIDCSecurityConfiguration.self)
            )
        }
        self.issuer = issuer
        self.audience = audience
        self.jwksURL = jwksURL
        self.jwksCacheTTL = max(0, jwksCacheTTL)
        self.clockSkewLeeway = max(0, clockSkewLeeway)
        self.jwksRefreshCooldown = max(0, jwksRefreshCooldown)
        self.jwksMaxStaleAge = max(0, jwksMaxStaleAge)
        self.jwksTransport = jwksTransport
        self.rolesClaims = rolesClaims
        self.scopesClaims = scopesClaims
    }

    /// Parses `security.oidc.jwks_transport`, refusing anything unrecognized
    /// rather than falling back — a typo here would otherwise silently pick a
    /// weaker transport than the operator wrote.
    static func transportPolicy(_ raw: String?) throws -> JWKSTransportPolicy {
        switch raw?.lowercased() {
        case nil, "https_only":
            return .httpsOnly
        case "allow_insecure_loopback":
            return .allowInsecureLoopback
        case "allow_insecure_anywhere":
            return .allowInsecureAnywhere
        case .some(let other):
            throw ConfigError.decodingFailed(
                key: "security.oidc.jwks_transport", rawValue: other,
                targetType: String(describing: JWKSTransportPolicy.self))
        }
    }

    /// Reads the `security.oidc.*` keys from Flight Config.
    /// Missing required keys fail here — surfaced at container freeze, so a
    /// misconfigured app fails at startup, not on its first request.
    public init(configuration: Configuration) throws {
        try self.init(
            issuer: configuration.get("security.oidc.issuer", as: String.self),
            audience: configuration.get("security.oidc.audience", as: String.self),
            jwksURL: configuration.getIfPresent("security.oidc.jwks_url", as: URL.self),
            jwksCacheTTL: try configuration.getIfPresent(
                "security.oidc.jwks_cache_ttl", as: Int.self).map(TimeInterval.init)
                ?? Defaults.jwksCacheTTL,
            clockSkewLeeway: try configuration.getIfPresent(
                "security.oidc.clock_skew_leeway", as: Int.self).map(TimeInterval.init)
                ?? Defaults.clockSkewLeeway,
            jwksRefreshCooldown: try configuration.getIfPresent(
                "security.oidc.jwks_refresh_cooldown", as: Int.self).map(TimeInterval.init)
                ?? Defaults.jwksRefreshCooldown,
            jwksMaxStaleAge: try configuration.getIfPresent(
                "security.oidc.jwks_max_stale", as: Int.self).map(TimeInterval.init)
                ?? Defaults.jwksMaxStaleAge,
            jwksTransport: try Self.transportPolicy(
                configuration.getIfPresent("security.oidc.jwks_transport", as: String.self)),
            rolesClaims: Self.claimList(
                try configuration.getIfPresent("security.oidc.roles_claim", as: String.self),
                default: Defaults.rolesClaims
            ),
            scopesClaims: Self.claimList(
                try configuration.getIfPresent("security.oidc.scopes_claim", as: String.self),
                default: Defaults.scopesClaims
            )
        )
    }

    private static func claimList(_ raw: String?, default defaultValue: [String]) -> [String] {
        guard let raw else { return defaultValue }
        let entries = raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return entries.isEmpty ? defaultValue : entries
    }
}
