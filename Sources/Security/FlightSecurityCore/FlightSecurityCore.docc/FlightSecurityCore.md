# ``FlightSecurityCore``

Bring your own identity provider: configure OIDC, get a ``Principal`` on
every request.

## Overview

Flight does not implement authentication, and that is the design rather than
a gap. Rolling your own auth is how applications get broken. What a framework
can usefully do is make a real identity provider a matter of configuration,
and make the resulting identity available everywhere without ceremony.

``OIDCTokenValidator`` is the shipped validator, and for OIDC-compliant
providers it is configuration rather than code — Descope, Keycloak, Auth0,
Okta and Entra are all the same type with different values:

```yaml
security:
  issuer: https://example.eu.auth0.com/
  audience: https://api.example.com
```

JWTKit owns the cryptographic core — signature verification, JWS structure,
JWK parsing. This module owns the orchestration around it: key fetching and
rotation, and a claim policy where issuer must match, audience must include
this application, `exp`/`nbf` are enforced with configurable clock-skew
leeway, and `sub` is required.

## When your provider is not OIDC

``TokenValidator`` is one method — token in, ``Principal`` out. Conform to it
and register your type instead:

```swift
struct OpaqueTokenValidator: TokenValidator {
    func validate(_ token: String) async throws -> Principal {
        let session = try await sessions.lookup(token)
        return Principal(subject: session.userID, roles: session.roles)
    }
}
```

``JWKSSource`` is the narrower seam, for a provider that publishes keys
somewhere non-standard: keep the OIDC claim policy, change only where keys
come from. ``HTTPJWKSSource`` is the default, using OIDC discovery.

## Identity is request-scoped

``PrincipalHolder`` is a `.scoped` component: one per request, never shared
between them. A service reads the current identity by injecting it, with no
thread-locals and no argument threading:

```swift
@Service
final class OrderService: Sendable {
    @Inject var identity: PrincipalHolder

    func placeOrder(...) async throws {
        guard let principal = identity.principal else { throw SecurityError.unauthenticated }
        ...
    }
}
```

``AuthenticationState`` distinguishes *anonymous* from *authenticated*
rather than collapsing both into a nil check, so a route that genuinely
allows anonymous access says so.

## Key rotation is a liveness concern

A provider rotates its signing keys, and a validator that caches them
forever starts rejecting every valid token. ``OIDCSecurityConfiguration``
exposes the whole policy — cache TTL, refresh cooldown, and a maximum stale
age past which a cached key set is refused rather than trusted. The cooldown
is what stops a burst of tokens signed by an unknown key from becoming a
burst of JWKS fetches.

``JWKSTransportPolicy`` governs the fetch itself. It requires HTTPS by
default; relaxing that is possible and deliberately awkward.

## What it does not do

No session store, no password hashing, no login form, no token issuance, no
refresh flow. Those belong to your identity provider. This module's job is
the boundary: turn a credential into a `Principal` and make it available
where the request runs.

`FlightChannels` reuses that boundary — a `Principal` established during a
WebSocket's HTTP upgrade is what the channel's join sees.

## Topics

### Validating a token

- ``TokenValidator``
- ``OIDCTokenValidator``
- ``OIDCSecurityConfiguration``
- ``TokenValidationError``

### Where keys come from

- ``JWKSSource``
- ``HTTPJWKSSource``
- ``JWKSTransportPolicy``
- ``JWKSSourceError``

### Identity

- ``Principal``
- ``PrincipalHolder``
- ``AuthenticationState``

### Hosting

- ``FlightSecurityModule``
- ``SecurityError``
