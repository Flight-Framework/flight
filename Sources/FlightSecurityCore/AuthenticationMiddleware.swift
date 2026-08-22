import FlightWeb
import HTTPTypes

/// The authentication middleware (design §4): extracts the bearer token,
/// validates it, and — on success — publishes the ``Principal`` on the
/// request's scope (via the scoped ``PrincipalHolder`` bean).
///
/// Authentication is deliberately not enforcement (design §5): requests
/// with no token, and requests whose token fails validation, both
/// `.continue` as unauthenticated. Rejection is ``requireAuthentication``'s
/// job (or a handler-level guard), so public routes stay public.
///
/// This overload resolves the ``TokenValidator`` from the container on each
/// request (a post-freeze dictionary read). It is what
/// ``FlightSecurityModule`` registers.
public func authenticationMiddleware() -> Middleware {
    { context in
        guard let validator = try? context.resolve((any TokenValidator).self) else {
            // A wiring bug, not a client error: fail closed, say nothing
            // token-specific to the wire.
            context.logger.error(
                "authentication middleware is registered but no TokenValidator bean is resolvable"
            )
            return .respond(.problem(status: .internalServerError, message: "Internal Server Error"))
        }
        return await authenticate(&context, using: validator)
    }
}

/// ``authenticationMiddleware()`` with an explicit validator, for manual
/// wiring or tests.
public func authenticationMiddleware(validator: any TokenValidator) -> Middleware {
    { context in
        await authenticate(&context, using: validator)
    }
}

private func authenticate(
    _ context: inout RequestContext,
    using validator: any TokenValidator
) async -> MiddlewareResult {
    guard let token = context.request.bearerToken else {
        // No credential: unauthenticated, not an error (design §4).
        return .continue
    }
    guard let holder = try? context.resolve(PrincipalHolder.self) else {
        context.logger.error(
            "authentication middleware is registered but the PrincipalHolder scoped bean is not; register FlightSecurityModule"
        )
        return .respond(.problem(status: .internalServerError, message: "Internal Server Error"))
    }
    do {
        let principal = try await validator.validate(token)
        holder.set(.authenticated(principal))
        // Stamp the identity onto the request logger so downstream log
        // lines correlate — the subject is the IdP's opaque id, not PII
        // Flight invents.
        context.logger[metadataKey: "auth.subject"] = "\(principal.subject)"
        return .continue
    } catch {
        // Error hygiene (design §3.2): the specific reason stays in the
        // internal log; the wire sees nothing here, and enforcement points
        // return a generic 401.
        context.logger.info(
            "token validation failed",
            metadata: ["reason": "\(error)"]
        )
        holder.set(.invalidCredential)
        return .continue
    }
}

/// Rejects requests with no valid principal (design §5.1). Enforcement of
/// *authentication*, not authorization — "is there anyone here", not "is
/// this the right someone".
///
/// Registered middleware is global in Flight Web's pipeline, so adding this
/// via `container.registerMiddleware` protects every route. For selective
/// protection, use the handler-level guards
/// (`context.requirePrincipal()` / `requireRole` / `requireScope`) instead.
///
/// Responses carry an RFC 6750 `WWW-Authenticate: Bearer` challenge;
/// `error="invalid_token"` distinguishes a rejected credential from an
/// absent one — and nothing more (design §3.2: no detail reaches the wire).
public let requireAuthentication: Middleware = { context in
    switch context.authenticationState {
    case .authenticated:
        return .continue
    case .anonymous:
        return .respond(
            .problem(status: .unauthorized, message: "Unauthorized")
                .settingHeader(.wwwAuthenticate, "Bearer")
        )
    case .invalidCredential:
        return .respond(
            .problem(status: .unauthorized, message: "Unauthorized")
                .settingHeader(.wwwAuthenticate, #"Bearer error="invalid_token""#)
        )
    }
}
