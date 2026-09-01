import FlightWeb

extension RequestContext {
    /// The authenticated principal for this request, or `nil` when the
    /// request is unauthenticated.
    ///
    /// Backed by the request-scoped ``PrincipalHolder`` bean; returns `nil`
    /// when ``FlightSecurityModule`` (or an equivalent registration) is not
    /// installed.
    public var principal: Principal? {
        (try? resolve(PrincipalHolder.self))?.principal
    }

    /// The full authentication outcome, distinguishing "no credential" from
    /// "rejected credential".
    public var authenticationState: AuthenticationState {
        (try? resolve(PrincipalHolder.self))?.state ?? .anonymous
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
