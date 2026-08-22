import FlightWeb

/// Enforcement errors thrown by application code and the request-context
/// guards (design §4/§5.1).
///
/// Conforms to `HTTPErrorRepresentable`, so a throw from a handler renders
/// as a bare 401/403 with a generic message — never validation detail
/// (design §3.2 error hygiene).
public enum SecurityError: Error, Sendable, Equatable, CustomStringConvertible {
    /// No authenticated principal on the current request.
    case unauthenticated
    /// An authenticated principal lacks a required role or scope.
    case forbidden

    public var description: String {
        switch self {
        case .unauthenticated: "unauthenticated: no valid principal on the current request"
        case .forbidden: "forbidden: principal lacks a required role or scope"
        }
    }
}

extension SecurityError: HTTPErrorRepresentable {
    public var httpStatus: Status {
        switch self {
        case .unauthenticated: .unauthorized
        case .forbidden: .forbidden
        }
    }

    /// Client-visible message; deliberately generic.
    public var httpMessage: String {
        switch self {
        case .unauthenticated: "Unauthorized"
        case .forbidden: "Forbidden"
        }
    }
}
