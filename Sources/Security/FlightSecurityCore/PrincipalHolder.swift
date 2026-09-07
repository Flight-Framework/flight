import Synchronization

/// The authentication outcome for one request.
///
/// Distinguishes "nobody presented a credential" from "a credential was
/// presented and rejected" — `requireAuthentication` uses the distinction to
/// emit an RFC 6750-correct `WWW-Authenticate` challenge.
public enum AuthenticationState: Sendable {
    /// No bearer token was presented.
    case anonymous
    /// A bearer token was presented but failed validation. The failure
    /// detail stays in the internal log (design error hygiene).
    case invalidCredential
    /// A bearer token was presented and validated.
    case authenticated(Principal)

    public var principal: Principal? {
        if case .authenticated(let principal) = self { return principal }
        return nil
    }
}

/// Per-request carrier for the authentication state.
///
/// Registered by ``FlightSecurityModule`` as a `.scoped` component, so each
/// request's `Scope` holds exactly one. The authentication middleware writes
/// it; handlers read it through `context.principal` /
/// `context.authenticationState`.
///
/// This is a reference type doing its own internal mutation because the
/// request `Scope`'s component cache is get-or-create: the *instance* is fixed at
/// first resolve, the *state* is set once the token is validated.
///
/// It exists because the middleware chain was a flat sequential loop when it
/// was written, so a task-local bound inside the authentication middleware
/// unwound before the handler ran. `compose(_:around:)` folds the chain into
/// layers now — each middleware calls `next(context)` inside its own extent —
/// so that constraint no longer holds, and neither does the reason for a
/// mutable reference type here. The composition migration replaces this with
/// a typed value on `RequestContext`, written by the authentication
/// middleware and read by the constructor of whatever needs it.
public final class PrincipalHolder: Sendable {
    private let storage = Mutex<AuthenticationState>(.anonymous)

    public init() {}

    public var state: AuthenticationState {
        storage.withLock { $0 }
    }

    public var principal: Principal? {
        state.principal
    }

    public func set(_ state: AuthenticationState) {
        storage.withLock { $0 = state }
    }
}
