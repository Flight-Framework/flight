import FlightWeb

extension RequestContext {
    /// The authenticated principal for this request, or `nil` when the
    /// request is unauthenticated.
    ///
    /// Read straight off the context: ``Authentication`` writes the identity
    /// into the copy it passes downstream, so a handler sees it without
    /// resolving anything. `nil` when the request is unauthenticated, and
    /// when no authentication middleware ran at all.
    public var principal: Principal? {
        identity.principal as? Principal
    }

    /// The full authentication outcome, distinguishing "no credential" from
    /// "rejected credential".
    public var authenticationState: AuthenticationState {
        AuthenticationState(identity)
    }

    /// Runs `operation` with `Principal.current` bound to this request's
    /// principal (or `nil` when unauthenticated), so services can read the
    /// ambient identity without threading it through every signature
    ///:
    ///
    /// ```swift
    /// @GetRoute("/documents")
    /// func documents(_ context: RequestContext) async throws -> Response {
    ///     try await context.withPrincipal {
    ///         .json(try await documentService.currentUsersDocuments())
    ///     }
    /// }
    /// ```
    ///
    /// The binding propagates to structured child tasks but not across
    /// `Task.detached`.
    public func withPrincipal<T>(_ operation: () async throws -> T) async rethrows -> T {
        try await Principal.$current.withValue(principal, operation: operation)
    }

    /// Returns the current principal or throws ``SecurityError/unauthenticated``
    /// (rendered as an opaque 401). The "is there *anyone* here" check
    ///, as a handler-level guard.
    @discardableResult
    public func requirePrincipal() throws -> Principal {
        guard let principal else { throw SecurityError.unauthenticated }
        return principal
    }

    /// Handler-level sugar over the manual check:
    /// `guard Principal.current?.hasRole("admin") == true`. Throws
    /// ``SecurityError/unauthenticated`` (401) with no principal, or
    /// ``SecurityError/forbidden`` (403) when the role is missing.
    @discardableResult
    public func requireRole(_ role: String) throws -> Principal {
        let principal = try requirePrincipal()
        guard principal.hasRole(role) else { throw SecurityError.forbidden }
        return principal
    }

    /// Like ``requireRole(_:)``, for OAuth2 scopes.
    @discardableResult
    public func requireScope(_ scope: String) throws -> Principal {
        let principal = try requirePrincipal()
        guard principal.hasScope(scope) else { throw SecurityError.forbidden }
        return principal
    }
}
