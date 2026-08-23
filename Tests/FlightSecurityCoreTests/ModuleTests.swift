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

    @Test("the module registers the OIDC validator, holder, and middleware")
    func registersEverything() throws {
        let module = FlightSecurityModule()
        let container = try TestContainer.build(configuration: minimalConfig) { module }

        let validator = try container.resolve((any TokenValidator).self)
        #expect(validator is OIDCTokenValidator)

        // The scoped holder resolves per scope — same instance within one,
        // fresh across scopes.
        let scopeA = Scope()
        let holderA1 = try container.resolve(PrincipalHolder.self, in: scopeA)
        let holderA2 = try container.resolve(PrincipalHolder.self, in: scopeA)
        #expect(holderA1 === holderA2)
        let holderB = try container.resolve(PrincipalHolder.self, in: Scope())
        #expect(holderA1 !== holderB)

        let middleware = try container.collectMiddleware()
        let auth = middleware.first { $0.name == "flight.security.authentication" }
        #expect(auth != nil)
        #expect(auth?.order == FlightSecurityModule.middlewareOrder)

        #expect(module.service != nil, "OIDC path owns the JWKS maintenance service")
    }

    @Test("missing required configuration fails at startup, not first request")
    func missingConfiguration() {
        #expect(throws: (any Error).self) {
            try TestContainer.build { FlightSecurityModule() }
        }
        #expect(throws: (any Error).self) {
            try TestContainer.build(
                configuration: Configuration(values: ["security.oidc.issuer": testIssuer])
            ) { FlightSecurityModule() }
        }
    }

    @Test("a custom TokenValidator registered first wins — the seam")
    func customValidatorWins() throws {
        let stub = StubValidator(principalsByToken: ["t": testPrincipal()])
        let securityModule = FlightSecurityModule()
        // No security.oidc.* configuration at all: the module must not
        // demand OIDC config when the app brought its own validator.
        let container = try TestContainer.build {
            CustomValidatorModule(validator: stub)
            securityModule
        }

        let validator = try container.resolve((any TokenValidator).self)
        #expect(validator is StubValidator)
        #expect(securityModule.service == nil, "no JWKS to maintain for a custom validator")
        #expect(
            try container.collectMiddleware()
                .contains { $0.name == "flight.security.authentication" },
            "middleware still registered"
        )
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
        container.register((any TokenValidator).self, scope: .singleton) { _ in validator }
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
