import Synchronization

/// The authentication outcome for one request (design §4/§5.1).
///
/// Distinguishes "nobody presented a credential" from "a credential was
/// presented and rejected" — `requireAuthentication` uses the distinction to
/// emit an RFC 6750-correct `WWW-Authenticate` challenge.
public enum AuthenticationState: Sendable {
    /// No bearer token was presented.
    case anonymous
    /// A bearer token was presented but failed validation. The failure
    /// detail stays in the internal log (design §3.2 error hygiene).
    case invalidCredential
    /// A bearer token was presented and validated.
    case authenticated(Principal)

    public var principal: Principal? {
        if case .authenticated(let principal) = self { return principal }
        return nil
    }
}

/// Per-request carrier for the authentication state (design §4).
///
/// Registered by ``FlightSecurityModule`` as a `.scoped` bean, so each
/// request's `Scope` holds exactly one. The authentication middleware writes
/// it; handlers read it through `context.principal` /
/// `context.authenticationState`.
///
/// This is a reference type doing its own internal mutation because the
/// request `Scope`'s bean cache is get-or-create: the *instance* is fixed at
/// first resolve, the *state* is set once the token is validated. It exists
/// because Flight Web's middleware chain is flat — a task-local bound inside
/// the authentication middleware would unwind before the handler runs, so
/// the principal must travel on the request scope instead.
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
