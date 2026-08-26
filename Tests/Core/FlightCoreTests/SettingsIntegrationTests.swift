// End-to-end: @Settings expanding for real, against a live container and
// real Configuration — the "does the generated code actually behave" layer,
// same split as MacroIntegrationTests.

import Synchronization
import Testing

@testable import FlightCore

// MARK: - Settings types under test

@Settings("auth")
struct AuthFixtureSettings: Sendable {
    var issuer: String = "myapp"
    @Secret var signingKey: String
    var tokenLifetime: Duration = .seconds(12 * 3_600)

    enum ValidationError: Error, Equatable {
        case signingKeyTooShort
    }

    func validate() throws {
        guard signingKey.count >= 8 else { throw ValidationError.signingKeyTooShort }
    }
}

@Settings("server")
struct ServerFixtureSettings: Sendable {
    var port: Int = 8080
}

@Settings("legacy")
struct OverriddenKeyFixtureSettings: Sendable {
    @ConfigValue("legacy.old-name", default: "fallback") var value: String
}

@Component
struct NeedsSettingsFixture: Sendable {
    @Autowired var server: ServerFixtureSettings
}

@Suite("@Settings integration — generated code against a live container")
struct SettingsIntegrationTests {

    @Test("required and optional properties bind from real Configuration")
    func bindsFromConfiguration() throws {
        let container = Container()
        container.register(Configuration.self, scope: .singleton) { _ in
            Configuration(values: [
                "auth.signing-key": "at-least-eight-characters",
                "auth.token-lifetime": "1h",
                // issuer left unset: default applies.
            ])
        }
        try AuthFixtureSettings._flightRegister(container)
        try container.freeze()

        let settings = try container.resolve(AuthFixtureSettings.self)
        #expect(settings.issuer == "myapp")
        #expect(settings.signingKey == "at-least-eight-characters")
        #expect(settings.tokenLifetime == .seconds(3_600))
    }

    @Test("a missing required key fails at freeze, not on first use")
    func requiredKeyMissingFailsAtFreeze() throws {
        let container = Container()
        container.register(Configuration.self, scope: .singleton) { _ in
            Configuration(values: [:])  // no auth.signing-key
        }
        try AuthFixtureSettings._flightRegister(container)

        #expect(throws: (any Error).self) {
            try container.freeze()
        }
    }

    @Test("validate() runs once at construction and can reject a bound value")
    func validateRejectsBadValue() throws {
        let container = Container()
        container.register(Configuration.self, scope: .singleton) { _ in
            Configuration(values: ["auth.signing-key": "short"])
        }
        try AuthFixtureSettings._flightRegister(container)

        #expect(throws: AuthFixtureSettings.ValidationError.signingKeyTooShort) {
            try container.freeze()
        }
    }

    @Test("resolvable anywhere @Autowired works, like any other component")
    func resolvableByAutowiring() throws {
        let container = Container()
        container.register(Configuration.self, scope: .singleton) { _ in
            Configuration(values: ["server.port": "9090"])
        }
        try ServerFixtureSettings._flightRegister(container)
        try NeedsSettingsFixture._flightRegister(container)
        try container.freeze()

        #expect(try container.resolve(NeedsSettingsFixture.self).server.port == 9090)
    }

    @Test("it registers under the .settings stereotype")
    func registeredUnderSettingsStereotype() throws {
        let container = Container()
        container.register(Configuration.self, scope: .singleton) { _ in
            Configuration(values: ["server.port": "9090"])
        }
        try ServerFixtureSettings._flightRegister(container)
        try container.freeze()

        let registration = try #require(
            container.allRegistrations().first { $0.typeName.contains("ServerFixtureSettings") })
        #expect(registration.stereotype == .settings)
    }

    @Test("@ConfigValue inside @Settings overrides the derived key")
    func explicitKeyOverrideBindsCorrectly() throws {
        let container = Container()
        container.register(Configuration.self, scope: .singleton) { _ in
            Configuration(values: ["legacy.old-name": "overridden"])
        }
        try OverriddenKeyFixtureSettings._flightRegister(container)
        try container.freeze()

        #expect(try container.resolve(OverriddenKeyFixtureSettings.self).value == "overridden")
    }

    @Test("@Secret redacts its field in the generated description")
    func secretFieldIsRedactedInDescription() throws {
        let container = Container()
        container.register(Configuration.self, scope: .singleton) { _ in
            Configuration(values: ["auth.signing-key": "at-least-eight-characters"])
        }
        try AuthFixtureSettings._flightRegister(container)
        try container.freeze()

        let description = String(describing: try container.resolve(AuthFixtureSettings.self))
        #expect(description.contains("<REDACTED>"))
        #expect(!description.contains("at-least-eight-characters"))
        // The non-secret field still renders — redaction is per-field, not
        // "hide the whole object because something in it is sensitive."
        #expect(description.contains("myapp"))
    }
}
