import FlightCore
import FlightWeb
import FlightWebTesting
import Foundation
import Testing

@testable import FlightSecurityCore

@Suite("Module wiring and configuration")
struct ModuleTests {
    private var minimalConfig: Configuration {
        Configuration(values: [
            "security.oidc.issuer": testIssuer,
            "security.oidc.audience": testAudience,
        ])
    }

    @Test("the security module registers the holder and middleware, but no validator")
    func securityModuleRegistersAuthenticationOnly() throws {
        let module = FlightSecurityModule()
        let container = try TestContainer.build {
            module
            CustomValidatorModule(validator: StubValidator(principalsByToken: [:]))
            MiddlewareScannerStandIn()
        }

        // The scoped holder resolves per scope — same instance within one,
        // fresh across scopes.
        let scopeA = Scope()
        let holderA1 = try container.resolve(PrincipalHolder.self, in: scopeA)
        let holderA2 = try container.resolve(PrincipalHolder.self, in: scopeA)
        #expect(holderA1 === holderA2)
        let holderB = try container.resolve(PrincipalHolder.self, in: Scope())
        #expect(holderA1 !== holderB)

        let middleware = try container.collectMiddleware()
        #expect(middleware.contains { $0.name.contains("Authentication") })

        #expect(module.service == nil, "JWKS maintenance belongs to FlightOIDCModule")
    }

    @Test("FlightOIDCModule supplies the validator and owns JWKS maintenance")
    func oidcModuleSuppliesValidator() throws {
        let oidc = FlightOIDCModule()
        let container = try TestContainer.build(configuration: minimalConfig) {
            oidc
            MiddlewareScannerStandIn()
        }

        let validator = try container.resolve((any TokenValidator).self)
        #expect(validator is OIDCTokenValidator)
        #expect(oidc.service != nil, "OIDC owns the JWKS maintenance service")

        // Listing FlightOIDCModule pulls FlightSecurityModule in transitively,
        // so the holder and middleware arrive without naming them.
        _ = try container.resolve(PrincipalHolder.self, in: Scope())
        #expect(
            try container.collectMiddleware()
                .contains { $0.name.contains("Authentication") }
        )
    }

    @Test("missing OIDC configuration fails at startup, not first request")
    func missingConfiguration() {
        #expect(throws: (any Error).self) {
            try TestContainer.build { FlightOIDCModule() }
        }
        #expect(throws: (any Error).self) {
            try TestContainer.build(
                configuration: Configuration(values: ["security.oidc.issuer": testIssuer])
            ) { FlightOIDCModule() }
        }
    }

    @Test("any validator works: supply one and omit FlightOIDCModule — no ordering")
    func customValidatorNeedsNoOrdering() throws {
        let stub = StubValidator(principalsByToken: ["t": testPrincipal()])

        // Listed *after* the security module, which under the old
        // scan-and-probe seam would have lost to the OIDC default. Choosing
        // modules has no such ordering dependence. Note also that no
        // security.oidc.* configuration is present: nothing demands it when
        // FlightOIDCModule isn't listed.
        let container = try TestContainer.build {
            FlightSecurityModule()
            CustomValidatorModule(validator: stub)
            MiddlewareScannerStandIn()
        }

        #expect(try container.resolve((any TokenValidator).self) is StubValidator)
        #expect(
            try container.collectMiddleware()
                .contains { $0.name.contains("Authentication") },
            "middleware still registered"
        )
    }

    @Test("security module without any validator fails loudly at freeze")
    func noValidatorFailsAtStartup() {
        #expect(throws: (any Error).self) {
            try TestContainer.build {
                FlightSecurityModule()
                MiddlewareScannerStandIn()
            }
        }
    }

    @Test("configuration keys map onto OIDCSecurityConfiguration with documented defaults")
    func configurationDefaults() throws {
        let config = try OIDCSecurityConfiguration(configuration: minimalConfig)
        #expect(config.issuer == testIssuer)
        #expect(config.audience == testAudience)
        #expect(config.jwksURL == nil)
        #expect(config.jwksCacheTTL == 3600)
        #expect(config.clockSkewLeeway == 60)
        #expect(config.jwksRefreshCooldown == 30)
        #expect(config.rolesClaims == ["roles", "groups", "realm_access.roles"])
        #expect(config.scopesClaims == ["scope", "scp"])
    }

    @Test("every documented key is read")
    func configurationOverrides() throws {
        let config = try OIDCSecurityConfiguration(
            configuration: Configuration(values: [
                "security.oidc.issuer": "https://idp",
                "security.oidc.audience": "app",
                "security.oidc.jwks_url": "https://idp/keys",
                "security.oidc.jwks_cache_ttl": "600",
                "security.oidc.clock_skew_leeway": "5",
                "security.oidc.jwks_refresh_cooldown": "120",
                "security.oidc.roles_claim": "https://example.com/roles, groups",
                "security.oidc.scopes_claim": "scope",
            ])
        )
        #expect(config.jwksURL == URL(string: "https://idp/keys"))
        #expect(config.jwksCacheTTL == 600)
        #expect(config.clockSkewLeeway == 5)
        #expect(config.jwksRefreshCooldown == 120)
        #expect(config.rolesClaims == ["https://example.com/roles", "groups"])
        #expect(config.scopesClaims == ["scope"])
    }

    @Test("empty issuer or audience is rejected")
    func emptyRequiredValues() {
        #expect(throws: (any Error).self) {
            try OIDCSecurityConfiguration(issuer: "  ", audience: "app")
        }
        #expect(throws: (any Error).self) {
            try OIDCSecurityConfiguration(issuer: "https://idp", audience: "")
        }
    }

    @Test("the JWKS maintenance service pre-warms the cache at startup")
    func maintenancePrewarm() async throws {
        let identity = TestIdentity(kid: "svc-key")
        let source = try InMemoryJWKSSource(json: jwksJSON([identity]))
        let configuration = try OIDCSecurityConfiguration(issuer: testIssuer, audience: testAudience)
        let validator = OIDCTokenValidator(configuration: configuration, jwksSource: source)

        let container = Container()
        // The service resolves the concrete type now: it belongs to
        // FlightOIDCModule, which registered it, so there is nothing to
        // discover and no cast that can fail.
        container.register(OIDCTokenValidator.self, scope: .singleton) { _ in validator }
        try container.freeze()

        let service = JWKSMaintenanceService(container: container)
        let run = Task { try await service.run() }

        // Poll until the pre-warm fetch lands.
        for _ in 0..<100 where source.fetchCount == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(source.fetchCount == 1)

        run.cancel()
        _ = try? await run.value
    }
}
