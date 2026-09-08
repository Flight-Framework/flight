import FlightWeb

/// What authentication decided about a request.
///
/// A view of Flight Web's ``RequestIdentity``, which is where the state
/// actually lives: the identity rides `RequestContext` as a typed field,
/// written by ``Authentication`` into the copy it passes downstream.
///
/// This used to be stored in a `PrincipalHolder` — a `Mutex`-backed class
/// registered as a `.scoped` component, so that each request's `Scope` held
/// exactly one and the authentication middleware could mutate it in place.
/// Two reasons, both since dissolved. The chain was a flat sequence of
/// returns, so a value written into a downstream copy never reached the
/// handler; `compose(_:around:)` folds it into layers now. And
/// `RequestContext` could not name `Principal` without a dependency cycle,
/// which the seam protocol solves directly rather than by routing through
/// the container.
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

    init(_ identity: RequestIdentity) {
        switch identity {
        case .anonymous: self = .anonymous
        case .invalidCredential: self = .invalidCredential
        case .authenticated(let principal):
            // The seam is `any RequestPrincipal`, so an application that
            // writes its own conformer is legal and simply has no
            // `Principal` to report. Anonymous is the honest answer here
            // rather than a crash: this type is about *this* package's
            // identity model.
            self = (principal as? Principal).map { .authenticated($0) } ?? .anonymous
        }
    }
}

/// The identity model this package produces, as Flight Web needs to see it.
/// `subject` and `hasRole` are already `Principal`'s own members.
extension Principal: RequestPrincipal {}
