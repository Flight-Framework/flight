import FlightCore
import Foundation

/// Configuration of the generic OIDC validator (design §3.3, §6).
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

    /// Leeway applied to `exp` and `nbf` (design §3.2: JWTKit supplies the
    /// primitive; Flight sets the policy).
    public var clockSkewLeeway: TimeInterval

    /// Minimum interval between JWKS fetch attempts, so unknown-`kid`
    /// refreshes and failing endpoints cannot be leveraged into hammering
    /// the IdP.
    public var jwksRefreshCooldown: TimeInterval

    /// Claim names searched (in union) for roles. Each entry is an exact
    /// claim name first, else a dot-path into nested objects — the default
    /// covers plain `roles`, `groups`, and Keycloak's `realm_access.roles`.
    public var rolesClaims: [String]

    /// Claim names searched (in union) for OAuth2 scopes. Space-delimited
    /// string claims (`scope`) are split; array claims (`scp`) are taken
    /// element-wise.
    public var scopesClaims: [String]

    public init(
        issuer: String,
        audience: String,
        jwksURL: URL? = nil,
        jwksCacheTTL: TimeInterval = 3600,
        clockSkewLeeway: TimeInterval = 60,
        jwksRefreshCooldown: TimeInterval = 30,
        rolesClaims: [String] = ["roles", "groups", "realm_access.roles"],
        scopesClaims: [String] = ["scope", "scp"]
    ) throws {
        guard !issuer.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ConfigError.decodingFailed(
                key: "security.oidc.issuer", rawValue: issuer, targetType: OIDCSecurityConfiguration.self
            )
        }
        guard !audience.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ConfigError.decodingFailed(
                key: "security.oidc.audience", rawValue: audience, targetType: OIDCSecurityConfiguration.self
            )
        }
        self.issuer = issuer
        self.audience = audience
        self.jwksURL = jwksURL
        self.jwksCacheTTL = max(0, jwksCacheTTL)
        self.clockSkewLeeway = max(0, clockSkewLeeway)
        self.jwksRefreshCooldown = max(0, jwksRefreshCooldown)
        self.rolesClaims = rolesClaims
        self.scopesClaims = scopesClaims
    }

    /// Reads the `security.oidc.*` keys from Flight Config (design §6).
    /// Missing required keys fail here — surfaced at container freeze, so a
    /// misconfigured app fails at startup, not on its first request.
    public init(configuration: Configuration) throws {
        try self.init(
            issuer: configuration.get("security.oidc.issuer", as: String.self),
            audience: configuration.get("security.oidc.audience", as: String.self),
            jwksURL: configuration.getIfPresent("security.oidc.jwks_url", as: URL.self),
            jwksCacheTTL: TimeInterval(
                try configuration.getIfPresent("security.oidc.jwks_cache_ttl", as: Int.self) ?? 3600
            ),
            clockSkewLeeway: TimeInterval(
                try configuration.getIfPresent("security.oidc.clock_skew_leeway", as: Int.self) ?? 60
            ),
            jwksRefreshCooldown: TimeInterval(
                try configuration.getIfPresent("security.oidc.jwks_refresh_cooldown", as: Int.self) ?? 30
            ),
            rolesClaims: Self.claimList(
                try configuration.getIfPresent("security.oidc.roles_claim", as: String.self),
                default: ["roles", "groups", "realm_access.roles"]
            ),
            scopesClaims: Self.claimList(
                try configuration.getIfPresent("security.oidc.scopes_claim", as: String.self),
                default: ["scope", "scp"]
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
