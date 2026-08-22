# Flight Security Core

Federated authentication for Flight, per
[`flight-security-core-design.md`](../flight-security-core-design.md).

Flight Security Core turns an externally issued identity token into a
`Principal`, makes that principal available on the request, and provides the
enforcement point for authentication — plus the *seam* (not the engine) for
authorization. Authentication itself — credentials, passwords, sessions,
recovery — is federated to external identity providers (Descope, Keycloak,
Auth0, Okta, Entra); that code deliberately does not exist here (design §1).

What this package owns is narrow and standard: **validate a token**. Even
that delegates its cryptographic core to [JWTKit](https://github.com/vapor/jwt-kit)
(SSWG Graduated, SwiftCrypto-backed); Flight owns only the orchestration —
JWKS fetching/rotation, claim policy, and error hygiene (design §3).

## Quick start

```swift
import FlightCore
import FlightSecurityCore
import FlightWeb

try await bootstrap(
    configuration: .load(),
    modules: [
        FlightWebModule<FlightTransport>.self,
        FlightSecurityModule.self,
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
(design §3.3). The JWKS endpoint is resolved automatically via OIDC
discovery (`{issuer}/.well-known/openid-configuration`); set
`security.oidc.jwks_url` only for a non-discoverable setup.

### Reading the current user

```swift
@GetMapping("/documents")
func documents(_ context: RequestContext) async throws -> Response {
    let principal = try context.requirePrincipal()          // 401 when absent
    return .json(try await repository.documents(ownedBy: principal.subject))
}
```

`context.principal` is `nil` for unauthenticated requests;
`context.authenticationState` additionally distinguishes "no credential"
from "rejected credential".

For service code that shouldn't take a principal parameter, bind the
task-local around the call (design §4):

```swift
@GetMapping("/documents")
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

### Enforcement (design §5.1)

Authentication and enforcement are separate concerns: the authentication
middleware `.continue`s whether or not a token was presented or valid, so
public routes stay public. Reject where you choose to:

```swift
// Everything requires authentication (global middleware — Flight Web's
// pipeline has no per-route middleware):
container.registerMiddleware("app.require-auth", order: -50, requireAuthentication)

// Or per route, in the handler:
@PostMapping("/admin/users")
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
policies) is a marked next step, not an omission (design §5.2).

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
| `roles_claim`           | no       | `roles,groups,realm_access.roles` | Comma-separated claim names/dot-paths, unioned |
| `scopes_claim`          | no       | `scope,scp` | Same; space-delimited strings are split |

Missing required keys fail at container freeze — startup, not first request.

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

## Custom validators (the §3.3 seam)

Most IdPs need no code. For a genuinely non-standard provider, register your
own `(any TokenValidator)` singleton in a module configured **before**
`FlightSecurityModule` (list it earlier in the bootstrap `modules:` array):

```swift
final class MyValidatorModule: FlightModule {
    func configure(_ container: Container) throws {
        container.register((any TokenValidator).self, scope: .singleton) { _ in
            MyValidator()
        }
    }
}
```

`FlightSecurityModule` detects the existing registration, skips the OIDC
validator (and its config requirements and JWKS service), and still wires
the middleware and principal plumbing around your implementation.

## Deviations from the design doc's pseudocode

The design sketches `Principal.$current.set(principal, in: context.scope)` —
a task-local bound "to a scope". Flight Web's middleware chain is a flat
sequential loop (not an onion), so a task-local bound inside the
authentication middleware would unwind before the handler runs. The
implemented mechanism keeps the design's semantics with the real APIs:

- The principal rides the request's `Scope` as a `.scoped` bean
  (`PrincipalHolder`), read through `context.principal`.
- `Principal.current` still exists as a task-local; handlers opt in with
  `context.withPrincipal { ... }`, which binds it around service calls. The
  `Task.detached` caveat from design §4 applies unchanged.
- `context.request.bearerToken` is provided by this package (RFC 6750
  parsing); `.respond(.unauthorized)` from the sketch is spelled
  `.respond(.problem(status: .unauthorized, message: "Unauthorized"))` with
  the real Flight Web response API.

A future Flight Web seam that lets middleware wrap the downstream chain
would allow binding `Principal.current` for the whole handler
automatically; nothing here forecloses that.

## Non-goals

Per design §7: no first-party authentication (no passwords, sessions,
credential storage), no authorization engine in v1, no hand-rolled
cryptography, no per-vendor packages for OIDC-compliant providers, no token
issuance, no TLS opinions.

## Development

```sh
swift build
swift test    # 86 tests, hermetic (in-memory JWKS/HTTP fakes, injected clocks)
```

Depends on `flight-core` and `flight-web` by relative path, plus JWTKit and
AsyncHTTPClient (both SSWG).
