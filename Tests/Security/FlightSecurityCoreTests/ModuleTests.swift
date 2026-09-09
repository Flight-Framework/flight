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

    @Test("the security module declares middleware and lanes, but no validator")
    func securityModuleRegistersAuthenticationOnly() throws {
        // Declared as values now: the composition root hands them to
        // FlightWebModule alongside every other module's.
        let module = FlightSecurityModule(validator: StubValidator(principalsByToken: [:]))

        // The principal needs no registration at all: it rides
        // `RequestContext.identity` as a typed value rather than a `.scoped`
        // component resolved out of the request's scope.
        #expect(module.middleware.contains { $0.name.contains("Authentication") })
        // All three canonical lanes, so `pipelines: [.authenticated]` resolves.
        #expect(
            Set(module.middleware.map(\.lane)) == [.default, .authentication, .authenticated])

        #expect(module.service == nil, "JWKS maintenance belongs to FlightOIDCModule")
    }

    @Test("FlightOIDCModule supplies the validator and owns JWKS maintenance")
    func oidcModuleSuppliesValidator() throws {
        let oidc = try FlightOIDCModule(configuration: minimalConfig)

        // The validator is a value the OIDC module holds; the composition root
        // wires it into FlightSecurityModule by type.
        #expect(oidc.tokenValidator is OIDCTokenValidator)
        #expect(oidc.service != nil, "OIDC owns the JWKS maintenance service")

        // And the security module built from that validator declares its
        // middleware.
        #expect(
            FlightSecurityModule(validator: oidc.tokenValidator).middleware
                .contains { $0.name.contains("Authentication") }
        )
    }

    @Test("missing OIDC configuration fails at startup, not first request")
    func missingConfiguration() {
        // Earlier than it used to be: the validator is built when the module
        // is, so bad configuration fails at composition rather than at
        // freeze().
        #expect(throws: (any Error).self) {
            try FlightOIDCModule(configuration: Configuration())
        }
        #expect(throws: (any Error).self) {
            try FlightOIDCModule(
                configuration: Configuration(values: ["security.oidc.issuer": testIssuer]))
        }
    }

    @Test("any validator works: supply one and omit FlightOIDCModule — no ordering")
    func customValidatorNeedsNoOrdering() throws {
        let stub = StubValidator(principalsByToken: ["t": testPrincipal()])

        // You hand the validator to the module directly, so there is no
        // registration race to lose and no ordering dependence — and no
        // security.oidc.* configuration is demanded when FlightOIDCModule is
        // not composed. "No validator" is not a state the module can reach:
        // the initializer requires one.
        let security = FlightSecurityModule(validator: stub)
        #expect(
            security.middleware.contains { $0.name.contains("Authentication") },
            "middleware still declared"
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

        // The service takes the validator it maintains — no container, and
        // so nothing to discover and no cast that can fail.
        let service = JWKSMaintenanceService(validator: validator)
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
