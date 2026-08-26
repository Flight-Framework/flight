import FlightCore
import FlightWeb
import HTTPTypes

/// Extracts the bearer token, validates it, and — on success — publishes
/// the ``Principal`` on the request's scope (via the scoped
/// ``PrincipalHolder`` bean). Registered by ``FlightSecurityModule``.
///
/// Authentication is deliberately not enforcement: requests with no token,
/// and requests whose token fails validation, both continue as
/// unauthenticated. Rejection is ``RequireAuthentication``'s job (or a
/// handler-level guard), so public routes stay public.
///
/// `validator` arrives through the initializer like any other dependency —
/// there is no longer a separate "explicit validator, for manual wiring or
/// tests" entry point, because that entry point existed only to work around
/// a closure's inability to hold one. `Authentication(validator: someMock)`
/// is now the same call for both cases.
@Middleware
public struct Authentication: Sendable {
    // Parenthesized: the macro's generated `init(_flight:)` resolves this by
    // appending `.self` to the type text, and `any TokenValidator.self`
    // (unparenthesized) parses as a lookup for a nested type named `self`
    // inside the TokenValidator protocol, not as that existential's
    // metatype.
    @Autowired var validator: (any TokenValidator)

    /// For manual wiring or tests, where `@Autowired` has nothing to
    /// resolve from.
    public init(validator: any TokenValidator) {
        self.validator = validator
    }

    public func handle(_ context: RequestContext, next: Next) async throws -> Response {
        guard let token = context.request.bearerToken else {
            // No credential: unauthenticated, not an error.
            return try await next(context)
        }
        guard let holder = try? context.resolve(PrincipalHolder.self) else {
            // A wiring bug, not a client error: fail closed, say nothing
            // token-specific to the wire. `PrincipalHolder` is request-scoped
            // and so cannot be an `@Autowired` dependency of this singleton
            // (that would be the captive-dependency mistake Flight Core's
            // scope check exists to catch) — it is only absent at all if
            // this type is running without `FlightSecurityModule`, which is
            // what registers it.
            context.logger.error(
                "authentication middleware is registered but the PrincipalHolder scoped bean is not; register FlightSecurityModule"
            )
            return .problem(status: .internalServerError, message: "Internal Server Error")
        }
        do {
            let principal = try await validator.validate(token)
            holder.set(.authenticated(principal))
            // Stamp the identity onto the request logger so downstream log
            // lines correlate — the subject is the IdP's opaque id, not PII
            // Flight invents. A local copy: `context` is a value, and this
            // stamped logger is only meant for what runs after this point.
            var stamped = context
            stamped.logger[metadataKey: "auth.subject"] = "\(principal.subject)"
            return try await next(stamped)
        } catch {
            // Error hygiene: the specific reason stays in the internal log;
            // the wire sees nothing here, and enforcement points return a
            // generic 401.
            context.logger.info(
                "token validation failed",
                metadata: ["reason": "\(error)"]
            )
            holder.set(.invalidCredential)
            return try await next(context)
        }
    }
}

/// Rejects requests with no valid principal. Enforcement of
/// *authentication*, not authorization — "is there anyone here", not "is
/// this the right someone".
///
/// Not installed by ``FlightSecurityModule`` — an application adds it to its
/// own `container.pipeline { }` (after ``Authentication`` — it needs the
/// principal *this* request's authentication decided, not some other
/// request's) for the routes it wants protected. For selective protection,
/// use the handler-level guards (`context.requirePrincipal()` /
/// `requireRole` / `requireScope`) instead.
///
/// Responses carry an RFC 6750 `WWW-Authenticate: Bearer` challenge;
/// `error="invalid_token"` distinguishes a rejected credential from an
/// absent one — and nothing more (design: no detail reaches the wire).
@Middleware
public struct RequireAuthentication: Sendable {
    public init() {}

    public func handle(_ context: RequestContext, next: Next) async throws -> Response {
        switch context.authenticationState {
        case .authenticated:
            return try await next(context)
        case .anonymous:
            return .problem(status: .unauthorized, message: "Unauthorized")
                .settingHeader(.wwwAuthenticate, "Bearer")
        case .invalidCredential:
            return .problem(status: .unauthorized, message: "Unauthorized")
                .settingHeader(.wwwAuthenticate, #"Bearer error="invalid_token""#)
        }
    }
}
