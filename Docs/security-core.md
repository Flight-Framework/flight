# Flight Security Core

Federated authentication for Flight, per
Flight Web.

Flight Security Core turns an externally issued identity token into a
`Principal`, makes that principal available on the request, and provides the
enforcement point for authentication — plus the *seam* (not the engine) for
authorization. Authentication itself — credentials, passwords, sessions,
recovery — is federated to external identity providers (Descope, Keycloak,
Auth0, Okta, Entra); that code deliberately does not exist here.

What this package owns is narrow and standard: **validate a token**. Even
that delegates its cryptographic core to [JWTKit](https://github.com/vapor/jwt-kit)
(SSWG Graduated, SwiftCrypto-backed); Flight owns only the orchestration —
JWKS fetching/rotation, claim policy, and error hygiene.

## Quick start

```swift
import FlightCore
import FlightSecurityCore
import FlightWeb

try await bootstrap(
    configuration: .load(),
    modules: [
        FlightWebModule<FlightTransport>.self,
        FlightOIDCModule.self,
        AppModule.self,
    ]
)
```

```yaml
# flight.yaml
security:
  oidc:
    issuer: "https://example.descope.com"   # or Keycloak realm URL, Auth0 domain, …
    audience: "my-flight-app"
```

That's the whole provider integration: OIDC-compliant IdPs are
*configuration* of the one generic validator, not separate packages
(design). The JWKS endpoint is resolved automatically via OIDC
discovery (`{issuer}/.well-known/openid-configuration`); set
`security.oidc.jwks_url` only for a non-discoverable setup.

### Reading the current user

```swift
@GetRoute("/documents")
func documents(_ context: RequestContext) async throws -> Response {
    let principal = try context.requirePrincipal()          // 401 when absent
    return .json(try await repository.documents(ownedBy: principal.subject))
}
```

`context.principal` is `nil` for unauthenticated requests;
`context.authenticationState` additionally distinguishes "no credential"
from "rejected credential".

For service code that shouldn't take a principal parameter, bind the
task-local around the call:

```swift
@GetRoute("/documents")
func documents(_ context: RequestContext) async throws -> Response {
    try await context.withPrincipal {
        .json(try await documentService.currentUsersDocuments())
    }
}

@Service
final class DocumentService {
    func currentUsersDocuments() async throws -> [Document] {
        guard let principal = Principal.current else { throw SecurityError.unauthenticated }
        return try await repository.documents(ownedBy: principal.subject)
    }
}
```

`Principal.current` propagates to structured child tasks (`async let`, task
groups) but **not** across `Task.detached` — deliberately: a detached
background job should not silently inherit the requester's identity.

### Enforcement

Authentication and enforcement are separate concerns: the authentication
middleware `.continue`s whether or not a token was presented or valid, so
public routes stay public. Reject where you choose to:

```swift
// Everything requires authentication (global middleware — Flight Web's
// pipeline has no per-route middleware):
container.registerMiddleware("app.require-auth", order: -50, requireAuthentication)

// Or per route, in the handler:
@PostRoute("/admin/users")
func createUser(_ context: RequestContext) async throws -> Response {
    guard context.principal?.hasRole("admin") == true else {
        throw SecurityError.forbidden
    }
    // ... (equivalently: try context.requireRole("admin"))
}
```

`requireAuthentication` answers with a bare 401 plus an RFC 6750
`WWW-Authenticate: Bearer` challenge (`error="invalid_token"` when a
credential was presented and rejected — and no further detail).
`SecurityError.unauthenticated` / `.forbidden` thrown from handlers render
as generic 401/403.

Roles and scopes ride on the token, so v1 authorization is honest one-liners
(`hasRole`, `requireScope`, …). The declarative engine (`@Secured` macros,
policies) is a marked next step, not an omission.

## Configuration reference

All keys live under `security.oidc.` (env-var form `FLIGHT_SECURITY_OIDC_*`):

| key                     | required | default | meaning |
|-------------------------|----------|---------|---------|
| `issuer`                | yes      | —       | Must equal the token's `iss` exactly |
| `audience`              | yes      | —       | Token's `aud` must include it |
| `jwks_url`              | no       | OIDC discovery | Explicit JWKS endpoint |
| `jwks_cache_ttl`        | no       | `3600`  | Seconds keys stay fresh |
| `clock_skew_leeway`     | no       | `60`    | Seconds of leeway on `exp`/`nbf` |
| `jwks_refresh_cooldown` | no       | `30`    | Minimum seconds between JWKS fetches |
| `jwks_max_stale`        | no       | `21600` | Seconds a cached key set may be served while the IdP is unreachable |
| `jwks_transport`        | no       | `https_only` | `https_only`, `allow_insecure_loopback`, `allow_insecure_anywhere` |
| `roles_claim`           | no       | `roles,groups,realm_access.roles` | Comma-separated claim names/dot-paths, unioned |
| `scopes_claim`          | no       | `scope,scp` | Same; space-delimited strings are split |

Missing required keys fail at container freeze — startup, not first request.
An unrecognized `jwks_transport` value fails there too, rather than falling
back to a weaker setting than the operator wrote.

### Why the transport keys matter

Whoever answers the JWKS fetch chooses the public keys that verify every
token this service accepts. Someone able to intercept it serves their own
signing key and mints any principal they like, so `jwks_transport` is not a
hardening preference — it is the boundary the rest of this package's
guarantees sit behind. HTTPS is enforced on the discovery document, on the
`jwks_uri` it names, on an explicitly configured `jwks_url`, and on every
redirect hop the fetch actually follows.

`allow_insecure_loopback` exists for a local IdP container in development:
plaintext to `localhost`/`127.0.0.1`/`::1` and nowhere else, on the
reasoning that anyone able to intercept loopback traffic is already running
as you. `allow_insecure_anywhere` has no safe use against a remote host.

### Why stale keys expire

When a refresh fails, cached keys keep serving so an IdP blip does not take
the service down. That window is bounded by `jwks_max_stale`: past it, every
request fails — not only the one that happens to attempt the refresh. The
bound used to be checked on the refresh path alone, and refreshes are
cooldown-gated, so past the limit roughly one request per cooldown window was
refused while the rest went on validating against keys that might have been
revoked. Unbounded, a revoked key stays honored for as long
as the outage lasts — which is the exact window revocation exists to close.
Six hours is long enough to ride out a real outage and short enough that a
revocation takes effect the same day.

### Algorithms

A token's `alg` must be in `security.oidc.allowed_algorithms`, which defaults
to every asymmetric algorithm JWTKit verifies (`RS*`, `PS*`, `ES*`, `EdDSA`).
Narrow it to what your IdP issues:

```yaml
security:
  oidc:
    allowed_algorithms: RS256
```

The classic reason for an allowlist — an RS256 token replayed as HS256 with
the public key as the HMAC secret — is not reachable here: verification keys
come solely from the JWKS, and JWTKit's `JWK` has no symmetric type. That is
three separate facts staying true, though, and this is one check. The half
that earns its keep day to day is the narrowing: an IdP that starts issuing
something new does not silently start being trusted for it.

### Keys the IdP did not publish for signing

A JWK may carry `use` (`sig`/`enc`) or `key_ops`. Keys not published for
signature verification are dropped from the verification set rather than
being trusted to verify tokens — the cross-protocol mistake those fields
exist to prevent. Matched by position rather than by `kid`, since `kid` is
optional in RFC 7517 and a key without one used to slip through the filter.
A key set where *no* key carries a `kid` is legal and usable: tokens without
a `kid` are verified by trying every key in the set.

Claim-name entries match an exact top-level claim first (so Auth0-style
namespaced claims like `https://example.com/roles` work), then as a dot-path
into nested objects (Keycloak's `realm_access.roles`).

## What the validator enforces

For every request bearing `Authorization: Bearer <jwt>`:

- **Signature** — verified by JWTKit against the issuer's JWKS. `alg: none`
  is rejected outright; tokens without a `kid` are checked against all keys
  rather than trusting a default-key fallback.
- **Key rotation** — an unrecognized `kid` triggers one JWKS refetch,
  rate-limited by `jwks_refresh_cooldown` so garbage tokens can't hammer the
  IdP. Keys are cached process-wide for `jwks_cache_ttl`; a maintenance
  service pre-warms them at startup and refreshes on the TTL cadence. If the
  IdP blips, cached keys serve stale rather than failing every request.
- **Claims** — `iss` equals the configured issuer; `aud` (string or array)
  includes the configured audience (missing `aud` is a rejection); `exp`
  required and enforced, `nbf` enforced when present, both with
  `clock_skew_leeway`; `sub` required and non-empty.
- **Error hygiene** — the wire sees a generic 401 (or an anonymous
  `.continue` on unguarded routes); the precise reason
  (`TokenValidationError`) goes to the internal log only.

## Choosing how tokens are validated

`FlightSecurityModule` wires authentication — the request-scoped principal and
the `Authentication` middleware — but registers **no validator**. How tokens
are validated is chosen by listing a module:

- **`FlightOIDCModule`** for OIDC/JWT. It registers `OIDCTokenValidator` from
  `security.oidc.*` and owns the JWKS maintenance service. It depends on
  `FlightSecurityModule`, so listing it alone is enough.
- **A module of your own** that registers `(any TokenValidator)`, for session
  cookies, API keys, mTLS, HMAC, or anything else:

```swift
final class MyValidatorModule: FlightModule {
    func configure(_ container: Container) throws {
        container.register((any TokenValidator).self, scope: .singleton) { _ in
            MyValidator()
        }
    }
}
```

List it alongside `FlightSecurityModule` — **order does not matter**, and no
`security.oidc.*` configuration is required when `FlightOIDCModule` isn't
listed.

With neither, `(any TokenValidator)` is unregistered and `Authentication`
fails to resolve it at container freeze — at startup, naming the type.

> **Changed.** Previously `FlightSecurityModule` registered OIDC *unless* it
> found that you had already registered your own, by scanning the container.
> That required your module to be configured **before** it — register after,
> and your validator silently lost — and an internal flag decided whether the
> JWKS refresher ran. Choosing a module is explicit and order-independent.

## Implementation notes worth knowing

The design sketches `Principal.$current.set(principal, in: context.scope)` —
a task-local bound "to a scope". Flight Web's middleware chain is a flat
sequential loop (not an onion), so a task-local bound inside the
authentication middleware would unwind before the handler runs. The
implemented mechanism keeps the intended semantics with the real APIs:

- The principal rides the request's `Scope` as a `.scoped` component
  (`PrincipalHolder`), read through `context.principal`.
- `Principal.current` still exists as a task-local; handlers opt in with
  `context.withPrincipal { ... }`, which binds it around service calls. The
  `Task.detached` caveat from design applies unchanged.
- `context.request.bearerToken` is provided by this package (RFC 6750
  parsing); `.respond(.unauthorized)` from the sketch is spelled
  `.respond(.problem(status: .unauthorized, message: "Unauthorized"))` with
  the real Flight Web response API.

A future Flight Web seam that lets middleware wrap the downstream chain
would allow binding `Principal.current` for the whole handler
automatically; nothing here forecloses that.

## Non-goals

Per design: no first-party authentication (no passwords, sessions,
credential storage), no authorization engine in v1, no hand-rolled
cryptography, no per-vendor packages for OIDC-compliant providers, no token
issuance, no TLS opinions.

## Development

```sh
swift build
swift test    # 98 tests, hermetic (in-memory JWKS/HTTP fakes, injected clocks)
```

Depends on `flight-core` and `flight-web` by relative path, plus JWTKit and
AsyncHTTPClient (both SSWG).
