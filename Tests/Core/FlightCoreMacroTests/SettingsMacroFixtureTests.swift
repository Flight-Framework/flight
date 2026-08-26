// @Settings expansion fixtures — normative, same discipline as
// MacroFixtureTests: these expected-output strings are the specification.

import SwiftSyntax
import SwiftSyntaxMacroExpansion
import SwiftSyntaxMacros
import SwiftSyntaxMacrosGenericTestSupport
import Testing

@testable import FlightCoreMacrosImpl

private let settingsMacros: [String: MacroSpec] = [
    "Settings": MacroSpec(
        type: SettingsMacro.self,
        conformances: ["FlightCore._FlightRegistrable", "CustomStringConvertible"]),
    "ConfigValue": MacroSpec(type: ConfigValueMacro.self),
    "Secret": MacroSpec(type: SecretMacro.self),
    "Autowired": MacroSpec(type: AutowiredMacro.self),
]

@Suite("@Settings expansion")
struct SettingsMacroFixtureTests {

    @Test("every property optional: one getIfPresent-or-default line each, kebab-cased key")
    func allOptional() {
        assertMacroExpansion(
            """
            @Settings("auth")
            struct AuthSettings {
                var issuer: String = "myapp"
                var tokenLifetimeHours: Int = 12
            }
            """,
            expandedSource: """
                struct AuthSettings {
                    var issuer: String = "myapp"
                    var tokenLifetimeHours: Int = 12

                    internal init(_flight container: FlightCore.Container) throws {
                        self.issuer = try container.resolve(FlightCore.Configuration.self).getIfPresent("auth.issuer", as: String.self) ?? ("myapp")
                        self.tokenLifetimeHours = try container.resolve(FlightCore.Configuration.self).getIfPresent("auth.token-lifetime-hours", as: Int.self) ?? (12)
                    }

                    static func _flightRegister(_ container: FlightCore.Container) throws {
                        container.register(Self.self, scope: .singleton, stereotype: .settings) { c in
                            try Self(_flight: c)
                        }
                    }
                }

                extension AuthSettings: FlightCore._FlightRegistrable {
                }
                """,
            macroSpecs: settingsMacros
        )
    }

    @Test("a property with no default is required, and uses get(_:) not getIfPresent")
    func requiredProperty() {
        assertMacroExpansion(
            """
            @Settings("auth")
            struct AuthSettings {
                var signingKey: String
            }
            """,
            expandedSource: """
                struct AuthSettings {
                    var signingKey: String

                    internal init(_flight container: FlightCore.Container) throws {
                        self.signingKey = try container.resolve(FlightCore.Configuration.self).get("auth.signing-key", as: String.self)
                    }

                    static func _flightRegister(_ container: FlightCore.Container) throws {
                        container.register(Self.self, scope: .singleton, stereotype: .settings) { c in
                            try Self(_flight: c)
                        }
                    }
                }

                extension AuthSettings: FlightCore._FlightRegistrable {
                }
                """,
            macroSpecs: settingsMacros
        )
    }

    @Test("a validate() method is called after construction, inside the registration thunk")
    func validateIsCalled() {
        assertMacroExpansion(
            """
            @Settings("auth")
            struct AuthSettings {
                var signingKey: String

                func validate() throws {}
            }
            """,
            expandedSource: """
                struct AuthSettings {
                    var signingKey: String

                    func validate() throws {}

                    internal init(_flight container: FlightCore.Container) throws {
                        self.signingKey = try container.resolve(FlightCore.Configuration.self).get("auth.signing-key", as: String.self)
                    }

                    static func _flightRegister(_ container: FlightCore.Container) throws {
                        container.register(Self.self, scope: .singleton, stereotype: .settings) { c in
                            let value = try Self(_flight: c)
                            try value.validate()
                            return value
                        }
                    }
                }

                extension AuthSettings: FlightCore._FlightRegistrable {
                }
                """,
            macroSpecs: settingsMacros
        )
    }

    @Test("a static validate() does not count — only an instance method runs")
    func staticValidateIsIgnored() {
        assertMacroExpansion(
            """
            @Settings("auth")
            struct AuthSettings {
                var signingKey: String

                static func validate() throws {}
            }
            """,
            expandedSource: """
                struct AuthSettings {
                    var signingKey: String

                    static func validate() throws {}

                    internal init(_flight container: FlightCore.Container) throws {
                        self.signingKey = try container.resolve(FlightCore.Configuration.self).get("auth.signing-key", as: String.self)
                    }

                    static func _flightRegister(_ container: FlightCore.Container) throws {
                        container.register(Self.self, scope: .singleton, stereotype: .settings) { c in
                            try Self(_flight: c)
                        }
                    }
                }

                extension AuthSettings: FlightCore._FlightRegistrable {
                }
                """,
            macroSpecs: settingsMacros
        )
    }

    @Test("@ConfigValue overrides the derived key; its own default: argument supplies the fallback")
    func explicitKeyOverride() {
        // Not a property-level initializer: @ConfigValue's own peer macro
        // independently rejects one ("the container supplies the value at
        // construction") whether or not @Settings is also attached — that
        // rule is unconditional, so overriding a key inside @Settings uses
        // exactly the same default: argument @ConfigValue uses everywhere
        // else.
        assertMacroExpansion(
            """
            @Settings("auth")
            struct AuthSettings {
                @ConfigValue("legacy.audience", default: "myapp-web") var audience: String
            }
            """,
            expandedSource: """
                struct AuthSettings {
                    var audience: String

                    internal init(_flight container: FlightCore.Container) throws {
                        self.audience = try container.resolve(FlightCore.Configuration.self).getIfPresent("legacy.audience", as: String.self) ?? ("myapp-web")
                    }

                    static func _flightRegister(_ container: FlightCore.Container) throws {
                        container.register(Self.self, scope: .singleton, stereotype: .settings) { c in
                            try Self(_flight: c)
                        }
                    }
                }

                extension AuthSettings: FlightCore._FlightRegistrable {
                }
                """,
            macroSpecs: settingsMacros
        )
    }

    @Test("@Secret redacts that field in the generated description; other fields render plainly")
    func secretRedaction() {
        assertMacroExpansion(
            """
            @Settings("auth")
            struct AuthSettings {
                var issuer: String = "myapp"
                @Secret var signingKey: String
            }
            """,
            expandedSource: """
                struct AuthSettings {
                    var issuer: String = "myapp"
                    var signingKey: String

                    internal init(_flight container: FlightCore.Container) throws {
                        self.issuer = try container.resolve(FlightCore.Configuration.self).getIfPresent("auth.issuer", as: String.self) ?? ("myapp")
                        self.signingKey = try container.resolve(FlightCore.Configuration.self).get("auth.signing-key", as: String.self)
                    }

                    static func _flightRegister(_ container: FlightCore.Container) throws {
                        container.register(Self.self, scope: .singleton, stereotype: .settings) { c in
                            try Self(_flight: c)
                        }
                    }

                    public var description: String {
                        "AuthSettings(issuer: \\(String(reflecting: self.issuer)), signingKey: \\"<REDACTED>\\")"
                    }
                }

                extension AuthSettings: FlightCore._FlightRegistrable {
                }

                extension AuthSettings: Swift.CustomStringConvertible {
                }
                """,
            macroSpecs: settingsMacros
        )
    }

    @Test("a public type's registration thunk is public")
    func publicAccessMatchesType() {
        assertMacroExpansion(
            """
            @Settings("web")
            public struct WebSettings {
                var maxRequestBodyBytes: Int = 1_048_576
            }
            """,
            expandedSource: """
                public struct WebSettings {
                    var maxRequestBodyBytes: Int = 1_048_576

                    internal init(_flight container: FlightCore.Container) throws {
                        self.maxRequestBodyBytes = try container.resolve(FlightCore.Configuration.self).getIfPresent("web.max-request-body-bytes", as: Int.self) ?? (1_048_576)
                    }

                    public static func _flightRegister(_ container: FlightCore.Container) throws {
                        container.register(Self.self, scope: .singleton, stereotype: .settings) { c in
                            try Self(_flight: c)
                        }
                    }
                }

                extension WebSettings: FlightCore._FlightRegistrable {
                }
                """,
            macroSpecs: settingsMacros
        )
    }

    @Test("a computed property is left alone — not treated as a config binding")
    func computedPropertyIsIgnored() {
        assertMacroExpansion(
            """
            @Settings("auth")
            struct AuthSettings {
                var tokenLifetime: Duration = .hours(12)
                var tokenLifetimeSeconds: Double { tokenLifetime.components.seconds.magnitude.description.isEmpty ? 0 : 0 }
            }
            """,
            expandedSource: """
                struct AuthSettings {
                    var tokenLifetime: Duration = .hours(12)
                    var tokenLifetimeSeconds: Double { tokenLifetime.components.seconds.magnitude.description.isEmpty ? 0 : 0 }

                    internal init(_flight container: FlightCore.Container) throws {
                        self.tokenLifetime = try container.resolve(FlightCore.Configuration.self).getIfPresent("auth.token-lifetime", as: Duration.self) ?? (.hours(12))
                    }

                    static func _flightRegister(_ container: FlightCore.Container) throws {
                        container.register(Self.self, scope: .singleton, stereotype: .settings) { c in
                            try Self(_flight: c)
                        }
                    }
                }

                extension AuthSettings: FlightCore._FlightRegistrable {
                }
                """,
            macroSpecs: settingsMacros
        )
    }
}

// MARK: - Diagnostics

/// The extension conformance still appears on every invalid case below, even
/// though the member expansion added nothing. That is not a gap here — it is
/// `@Component`/`@Repository`'s own established, pinned behavior
/// (`MacroFixtureTests`'s nonfinal-class fixtures): the compiler invokes the
/// extension role independently of what the member role decided, and a
/// diagnostic emitted from the member role does not suppress it. `@Settings`
/// matches that precedent rather than inventing a different one.
@Suite("@Settings diagnostics")
struct SettingsMacroDiagnosticTests {

    @Test("no namespace argument is an error")
    func missingNamespace() {
        assertMacroExpansion(
            """
            @Settings
            struct AuthSettings {
                var issuer: String = "myapp"
            }
            """,
            expandedSource: """
                struct AuthSettings {
                    var issuer: String = "myapp"
                }

                extension AuthSettings: FlightCore._FlightRegistrable {
                }
                """,
            diagnostics: [
                DiagnosticSpec(message: "@Settings requires a namespace, as a string literal, e.g. @Settings(\"auth\").", line: 1, column: 1)
            ],
            macroSpecs: settingsMacros
        )
    }

    @Test("@Autowired inside @Settings is refused")
    func autowiredRefused() {
        assertMacroExpansion(
            """
            @Settings("auth")
            struct AuthSettings {
                @Autowired var logger: AppLogger
            }
            """,
            expandedSource: """
                struct AuthSettings {
                    var logger: AppLogger

                    internal init(_flight container: FlightCore.Container) throws {
                    }

                    static func _flightRegister(_ container: FlightCore.Container) throws {
                        container.register(Self.self, scope: .singleton, stereotype: .settings) { c in
                            try Self(_flight: c)
                        }
                    }
                }

                extension AuthSettings: FlightCore._FlightRegistrable {
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@Autowired is not valid inside @Settings — settings hold configuration only. Put dependencies in a @Service or @Component instead.",
                    line: 3, column: 5)
            ],
            macroSpecs: settingsMacros
        )
    }

    @Test("an Optional property is refused, with a fix in the message")
    func optionalRefused() {
        assertMacroExpansion(
            """
            @Settings("auth")
            struct AuthSettings {
                var nickname: String?
            }
            """,
            expandedSource: """
                struct AuthSettings {
                    var nickname: String?

                    internal init(_flight container: FlightCore.Container) throws {
                    }

                    static func _flightRegister(_ container: FlightCore.Container) throws {
                        container.register(Self.self, scope: .singleton, stereotype: .settings) { c in
                            try Self(_flight: c)
                        }
                    }
                }

                extension AuthSettings: FlightCore._FlightRegistrable {
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message: "'nickname' may not be Optional. Give it a concrete default instead of allowing absence — @Settings binds a value once, at bootstrap, and a key that may or may not exist has no single answer for 'what did we configure'.",
                    line: 3, column: 5)
            ],
            macroSpecs: settingsMacros
        )
    }

    @Test("a let with a default must be var, since the generated init overrides it")
    func letWithDefaultRefused() {
        assertMacroExpansion(
            """
            @Settings("auth")
            struct AuthSettings {
                let issuer: String = "myapp"
            }
            """,
            expandedSource: """
                struct AuthSettings {
                    let issuer: String = "myapp"

                    internal init(_flight container: FlightCore.Container) throws {
                    }

                    static func _flightRegister(_ container: FlightCore.Container) throws {
                        container.register(Self.self, scope: .singleton, stereotype: .settings) { c in
                            try Self(_flight: c)
                        }
                    }
                }

                extension AuthSettings: FlightCore._FlightRegistrable {
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message: "'issuer' has a default value, so it must be 'var' — the generated initializer assigns it when configuration supplies a value, overriding the default.",
                    line: 3, column: 5)
            ],
            macroSpecs: settingsMacros
        )
    }

    @Test("attaching to a non-final class is refused")
    func nonFinalClassRefused() {
        assertMacroExpansion(
            """
            @Settings("auth")
            class AuthSettings {
                var issuer: String = "myapp"
            }
            """,
            expandedSource: """
                class AuthSettings {
                    var issuer: String = "myapp"
                }

                extension AuthSettings: FlightCore._FlightRegistrable {
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@Settings requires a final class (or a struct). Mark 'AuthSettings' final.",
                    line: 2, column: 7)
            ],
            macroSpecs: settingsMacros
        )
    }
}
