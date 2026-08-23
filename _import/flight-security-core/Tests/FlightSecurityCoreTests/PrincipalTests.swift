import Testing

@testable import FlightSecurityCore

@Suite("Principal — the authenticated identity")
struct PrincipalTests {
    @Test("hasRole reflects the roles set")
    func hasRole() {
        let principal = testPrincipal(roles: ["admin", "editor"])
        #expect(principal.hasRole("admin"))
        #expect(principal.hasRole("editor"))
        #expect(!principal.hasRole("viewer"))
        #expect(!principal.hasRole("ADMIN"), "role comparison is exact, as issued by the IdP")
    }

    @Test("hasScope reflects the scopes set")
    func hasScope() {
        let principal = testPrincipal(scopes: ["read:documents", "write:documents"])
        #expect(principal.hasScope("read:documents"))
        #expect(!principal.hasScope("delete:documents"))
    }

    @Test("roles, scopes, and claims default to empty")
    func defaults() {
        let principal = Principal(subject: "u1", issuer: "https://idp")
        #expect(principal.roles.isEmpty)
        #expect(principal.scopes.isEmpty)
        #expect(principal.claims.isEmpty)
    }

    @Test("typed claim access casts, and misses return nil")
    func typedClaims() {
        let principal = Principal(
            subject: "u1",
            issuer: "https://idp",
            claims: [
                "email": "user@example.com",
                "age": 42,
                "verified": true,
                "tags": ["a", "b"],
            ]
        )
        #expect(principal.claim("email", as: String.self) == "user@example.com")
        #expect(principal.claim("age", as: Int.self) == 42)
        #expect(principal.claim("verified", as: Bool.self) == true)
        #expect(principal.claim("email", as: Int.self) == nil, "wrong type is nil, not a trap")
        #expect(principal.claim("missing", as: String.self) == nil)
    }

    @Test("Principal.current is nil outside any binding")
    func taskLocalDefault() {
        #expect(Principal.current == nil)
    }

    @Test("Principal.current propagates to structured children but not Task.detached")
    func taskLocalPropagation() async {
        let principal = testPrincipal(subject: "task-local-user")
        await Principal.$current.withValue(principal) {
            #expect(Principal.current?.subject == "task-local-user")

            // Structured concurrency inherits the binding.
            async let childSubject = Principal.current?.subject
            #expect(await childSubject == "task-local-user")

            await withTaskGroup(of: String?.self) { group in
                group.addTask { Principal.current?.subject }
                let seen = await group.next() ?? nil
                #expect(seen == "task-local-user")
            }

            // Task.detached deliberately does not — a detached background
            // job must not silently inherit the requester's identity.
            let detached = Task.detached { Principal.current?.subject }
            #expect(await detached.value == nil)
        }
        #expect(Principal.current == nil, "binding unwinds with the closure")
    }
}
