// End-to-end: @Settings expanding for real against real Configuration.
// A settings type builds through its generated init(_flightConfiguration:)
// — the same initializer the composition root's graph calls.

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
    @Inject var server: ServerFixtureSettings
}

@Suite("@Settings integration — generated code against real Configuration")
struct SettingsIntegrationTests {

    @Test("required and optional properties bind from real Configuration")
    func bindsFromConfiguration() throws {
        let settings = try AuthFixtureSettings(
            _flightConfiguration: Configuration(values: [
                "auth.signing-key": "at-least-eight-characters",
                "auth.token-lifetime": "1h",
                // issuer left unset: default applies.
            ]))
        #expect(settings.issuer == "myapp")
        #expect(settings.signingKey == "at-least-eight-characters")
        #expect(settings.tokenLifetime == .seconds(3_600))
    }

    @Test("a missing required key fails at construction, not on first use")
    func requiredKeyMissingFails() {
        #expect(throws: (any Error).self) {
            _ = try AuthFixtureSettings(_flightConfiguration: Configuration(values: [:]))
        }
    }

    @Test("validate() runs at construction and can reject a bound value")
    func validateRejectsBadValue() {
        #expect(throws: AuthFixtureSettings.ValidationError.signingKeyTooShort) {
            _ = try AuthFixtureSettings(
                _flightConfiguration: Configuration(values: ["auth.signing-key": "short"]))
        }
    }

    @Test("a settings type is an ordinary constructor dependency")
    func usableAsADependency() throws {
        let server = try ServerFixtureSettings(
            _flightConfiguration: Configuration(values: ["server.port": "9090"]))
        let consumer = NeedsSettingsFixture(server: server)
        #expect(consumer.server.port == 9090)
    }

    @Test("@ConfigValue inside @Settings overrides the derived key")
    func explicitKeyOverrideBindsCorrectly() throws {
        let settings = try OverriddenKeyFixtureSettings(
            _flightConfiguration: Configuration(values: ["legacy.old-name": "overridden"]))
        #expect(settings.value == "overridden")
    }

    @Test("@Secret redacts its field in the generated description")
    func secretFieldIsRedactedInDescription() throws {
        let settings = try AuthFixtureSettings(
            _flightConfiguration: Configuration(values: [
                "auth.signing-key": "at-least-eight-characters"
            ]))
        let description = String(describing: settings)
        #expect(description.contains("<REDACTED>"))
        #expect(!description.contains("at-least-eight-characters"))
    }
}
