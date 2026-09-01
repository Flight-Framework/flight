// §5.4 — the macro expansion spike, resolved as fixtures.
//
// These expected-output strings ARE the specification of Flight's macro
// expansions; the design doc's prose examples are illustrative, these are
// normative. Design decisions they pin (recorded in SPIKE-FINDINGS.md):
//
//  M-1  The resolving initializer is `init(_flight:)`, macro-generated.
//       The doc's `init() {}` alongside non-optional @Inject stored
//       properties cannot compile in real Swift — exactly the kind of
//       looks-obvious-doesn't-compile gap this fixture process exists to
//       catch. Component types should not declare their own initializers.
//  F-6  Two @Inject properties of one type without distinct explicit
//       qualifiers are a compile error (fixture 6a) — Flight refuses to
//       guess positionally. With qualifiers, resolution is explicit (6b).
//  T-1  @Transactional requires `throws`; the body is wrapped in an
//       immediately-invoked, explicitly-typed closure so `return` and
//       implicit `self` keep their meaning.
//
// NOTE ON FIRST RUN: expected strings were written without a toolchain to
// verify against (see README). assertMacroExpansion output formatting
// (BasicFormat) may disagree on whitespace/indentation, not substance —
// expect one mechanical alignment pass, then these freeze.

import SwiftSyntax
import SwiftSyntaxMacroExpansion
import SwiftSyntaxMacros
import SwiftSyntaxMacrosGenericTestSupport
import Testing

@testable import FlightCoreMacrosImpl

// MacroSpec (not a bare [String: Macro.Type]) so the harness knows the
// conformances `@attached(extension, conformances:)` declares — without it,
// the extension macro receives an empty `protocols` list and emits nothing,
// which diverges from real compilation (first-run finding; the runtime
// integration suite proves the compiler path emits the conformance).
private let testMacros: [String: MacroSpec] = [
    "Component": MacroSpec(
        type: ComponentMacro.self, conformances: ["FlightCore._FlightRegistrable"]),
    "Service": MacroSpec(type: ServiceMacro.self, conformances: ["FlightCore._FlightRegistrable"]),
    "Repository": MacroSpec(
        type: RepositoryMacro.self, conformances: ["FlightCore._FlightRegistrable"]),
    "Inject": MacroSpec(type: InjectMacro.self),
    "ConfigValue": MacroSpec(type: ConfigValueMacro.self),
    "Transactional": MacroSpec(type: TransactionalMacro.self),
    "Settings": MacroSpec(
        type: SettingsMacro.self,
        conformances: ["FlightCore._FlightRegistrable", "CustomStringConvertible"]),
    "Secret": MacroSpec(type: SecretMacro.self),
]

@Suite("macro fixture tests")
struct MacroFixtureTests {

    // MARK: Fixture 1 — a component with no dependencies

    @Test("plain component")
    func plainComponent() {
        assertMacroExpansion(
            """
            @Component
            final class ClockService {
                func now() -> Int { 0 }
            }
            """,
            expandedSource: """
                final class ClockService {
                    func now() -> Int { 0 }

                    internal init(_flight container: FlightCore.Container) throws {
                    }

                    static func _flightRegister(_ container: FlightCore.Container) throws {
                        container.register(Self.self, scope: .singleton) { c in
                            try Self(_flight: c)
                        }
                    }
                }

                extension ClockService: FlightCore._FlightRegistrable {
                }
                """,
            macroSpecs: testMacros
        )
    }

    // MARK: Fixture 2 — a component with @Inject dependencies
    // (public type, so the registration thunk is access-matched)

    @Test("component with dependencies")
    func componentWithDependencies() {
        assertMacroExpansion(
            """
            @Component
            public final class UserService {
                @Inject let repository: UserRepository
                @Inject let logger: AppLogger
            }
            """,
            expandedSource: """
                public final class UserService {
                    let repository: UserRepository
                    let logger: AppLogger

                    internal init(_flight container: FlightCore.Container) throws {
                        self.repository = try container.resolve(UserRepository.self)
                        self.logger = try container.resolve(AppLogger.self)
                    }

                    public static func _flightRegister(_ container: FlightCore.Container) throws {
                        container.register(Self.self, scope: .singleton) { c in
                            try Self(_flight: c)
                        }
                    }
                }

                extension UserService: FlightCore._FlightRegistrable {
                }
                """,
            macroSpecs: testMacros
        )
    }

    // MARK: Stereotypes (§5.1.1) — identical expansion, tagged register call

    @Test("service stereotype")
    func serviceStereotype() {
        assertMacroExpansion(
            """
            @Service
            final class BillingService {
                @Inject let repository: InvoiceRepository
            }
            """,
            expandedSource: """
                final class BillingService {
                    let repository: InvoiceRepository

                    internal init(_flight container: FlightCore.Container) throws {
                        self.repository = try container.resolve(InvoiceRepository.self)
                    }

                    static func _flightRegister(_ container: FlightCore.Container) throws {
                        container.register(Self.self, scope: .singleton, stereotype: .service) { c in
                            try Self(_flight: c)
                        }
                    }
                }

                extension BillingService: FlightCore._FlightRegistrable {
                }
                """,
            macroSpecs: testMacros
        )
    }

    @Test("repository stereotype")
    func repositoryStereotype() {
        // Arguments compose exactly as on @Component.
        assertMacroExpansion(
            """
            @Repository(qualifier: "replica")
            public final class InvoiceRepository {
            }
            """,
            expandedSource: """
                public final class InvoiceRepository {

                    internal init(_flight container: FlightCore.Container) throws {
                    }

                    public static func _flightRegister(_ container: FlightCore.Container) throws {
                        container.register(Self.self, qualifier: "replica", scope: .singleton, stereotype: .repository) { c in
                            try Self(_flight: c)
                        }
                    }
                }

                extension InvoiceRepository: FlightCore._FlightRegistrable {
                }
                """,
            macroSpecs: testMacros
        )
    }

    @Test("stereotype diagnostics name the attribute")
    func stereotypeDiagnosticsNameTheAttribute() {
        assertMacroExpansion(
            """
            @Repository
            class OpenRepository {
            }
            """,
            expandedSource: """
                class OpenRepository {
                }

                extension OpenRepository: FlightCore._FlightRegistrable {
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message:
                        "@Repository requires a final class (or a struct). Mark 'OpenRepository' final.",
                    line: 2,
                    column: 7
                )
            ],
            macroSpecs: testMacros
        )
    }

    // MARK: Fixture 3 — @Transactional on a synchronous throwing method

    @Test("transactional sync")
    func transactionalSync() {
        assertMacroExpansion(
            """
            final class Ledger {
                @Transactional
                func post(_ amount: Int) throws -> Int {
                    try store.append(amount)
                    return amount
                }
            }
            """,
            expandedSource: """
                final class Ledger {
                    func post(_ amount: Int) throws -> Int {
                        let _flightTx = try FlightCore.FlightTransactions.coordinator.begin()
                        do {
                            let _flightResult: Int = try { () throws -> Int in
                                try store.append(amount)
                                return amount
                            }()
                            try FlightCore.FlightTransactions.coordinator.commit(_flightTx)
                            return _flightResult
                        } catch {
                            FlightCore.FlightTransactions.coordinator.rollback(_flightTx)
                            throw error
                        }
                    }
                }
                """,
            macroSpecs: testMacros
        )
    }

    // MARK: Fixture 4 — @Transactional on an async throwing method (Void)
    //
    // Async methods route through the preferring-async helpers (delta 14):
    // the async-native coordinator when one is bound, the sync coordinator
    // otherwise — selected at runtime, awaited rather than blocked on.

    @Test("transactional async void")
    func transactionalAsyncVoid() {
        assertMacroExpansion(
            """
            final class Mover {
                @Transactional
                func transfer(_ amount: Int) async throws {
                    try await debit(amount)
                    try await credit(amount)
                }
            }
            """,
            expandedSource: """
                final class Mover {
                    func transfer(_ amount: Int) async throws {
                        let _flightTx = try await FlightCore.FlightTransactions.beginPreferringAsync()
                        do {
                            try await { () async throws -> Void in
                                try await debit(amount)
                                try await credit(amount)
                            }()
                            try await FlightCore.FlightTransactions.commitPreferringAsync(_flightTx)
                        } catch {
                            await FlightCore.FlightTransactions.rollbackPreferringAsync(_flightTx)
                            throw error
                        }
                    }
                }
                """,
            macroSpecs: testMacros
        )
    }

    // MARK: Fixture 5 — a scoped component

    @Test("scoped component")
    func scopedComponent() {
        assertMacroExpansion(
            """
            @Component(scope: .scoped)
            final class RequestContext {
            }
            """,
            expandedSource: """
                final class RequestContext {

                    internal init(_flight container: FlightCore.Container) throws {
                    }

                    static func _flightRegister(_ container: FlightCore.Container) throws {
                        container.register(Self.self, scope: .scoped) { c in
                            try Self(_flight: c)
                        }
                    }
                }

                extension RequestContext: FlightCore._FlightRegistrable {
                }
                """,
            macroSpecs: testMacros
        )
    }

    // MARK: Fixture 6a — two @Inject of one type, no qualifiers: refuse

    @Test("ambiguous inject is compile error")
    func ambiguousInjectIsCompileError() {
        assertMacroExpansion(
            """
            @Component
            final class ReportService {
                @Inject var primary: DataSource
                @Inject var replica: DataSource
            }
            """,
            expandedSource: """
                final class ReportService {
                    var primary: DataSource
                    var replica: DataSource
                }

                extension ReportService: FlightCore._FlightRegistrable {
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message:
                        "Two @Inject properties of type 'DataSource' require distinct explicit qualifiers, e.g. @Inject(\"primary\").",
                    line: 4,
                    column: 5
                )
            ],
            macroSpecs: testMacros
        )
    }

    // MARK: Fixture 6b — the qualified resolution

    @Test("qualified inject")
    func qualifiedInject() {
        assertMacroExpansion(
            """
            @Component
            final class ReportService {
                @Inject("primary") var primary: DataSource
                @Inject("replica") var replica: DataSource
            }
            """,
            expandedSource: """
                final class ReportService {
                    var primary: DataSource
                    var replica: DataSource

                    internal init(_flight container: FlightCore.Container) throws {
                        self.primary = try container.resolve(DataSource.self, qualifier: "primary")
                        self.replica = try container.resolve(DataSource.self, qualifier: "replica")
                    }

                    static func _flightRegister(_ container: FlightCore.Container) throws {
                        container.register(Self.self, scope: .singleton) { c in
                            try Self(_flight: c)
                        }
                    }
                }

                extension ReportService: FlightCore._FlightRegistrable {
                }
                """,
            macroSpecs: testMacros
        )
    }

    // MARK: Supplementary — @ConfigValue expansion

    @Test("config value")
    func configValue() {
        assertMacroExpansion(
            """
            @Component
            final class ServerSettings {
                @ConfigValue("server.port") let port: Int
            }
            """,
            expandedSource: """
                final class ServerSettings {
                    let port: Int

                    internal init(_flight container: FlightCore.Container) throws {
                        self.port = try container.resolve(FlightCore.Configuration.self).get("server.port", as: Int.self)
                    }

                    static func _flightRegister(_ container: FlightCore.Container) throws {
                        container.register(Self.self, scope: .singleton) { c in
                            try Self(_flight: c)
                        }
                    }
                }

                extension ServerSettings: FlightCore._FlightRegistrable {
                }
                """,
            macroSpecs: testMacros
        )
    }

    // MARK: Supplementary — @ConfigValue with default: (Flight Config §5)
    //
    // Resolves through getIfPresent, not get(_:default:): absence applies the
    // default, but a present-and-malformed value still throws — failing the
    // owning module's configure(_:) loudly instead of silently taking the
    // default. The default expression is parenthesized so low-precedence
    // expressions cannot rebind against `??`.

    @Test("config value with default")
    func configValueWithDefault() {
        assertMacroExpansion(
            """
            @Component
            final class PoolSettings {
                @ConfigValue("datasource.pool_size", default: 10) let poolSize: Int
            }
            """,
            expandedSource: """
                final class PoolSettings {
                    let poolSize: Int

                    internal init(_flight container: FlightCore.Container) throws {
                        self.poolSize = try container.resolve(FlightCore.Configuration.self).getIfPresent("datasource.pool_size", as: Int.self) ?? (10)
                    }

                    static func _flightRegister(_ container: FlightCore.Container) throws {
                        container.register(Self.self, scope: .singleton) { c in
                            try Self(_flight: c)
                        }
                    }
                }

                extension PoolSettings: FlightCore._FlightRegistrable {
                }
                """,
            macroSpecs: testMacros
        )
    }

    // MARK: Supplementary — @Component qualifier argument

    @Test("component qualifier")
    func componentQualifier() {
        assertMacroExpansion(
            """
            @Component(qualifier: "primary")
            final class PrimarySource {
            }
            """,
            expandedSource: """
                final class PrimarySource {

                    internal init(_flight container: FlightCore.Container) throws {
                    }

                    static func _flightRegister(_ container: FlightCore.Container) throws {
                        container.register(Self.self, qualifier: "primary", scope: .singleton) { c in
                            try Self(_flight: c)
                        }
                    }
                }

                extension PrimarySource: FlightCore._FlightRegistrable {
                }
                """,
            macroSpecs: testMacros
        )
    }

    // MARK: Supplementary — diagnostics

    @Test("non final class is rejected")
    func nonFinalClassIsRejected() {
        assertMacroExpansion(
            """
            @Component
            class OpenService {
            }
            """,
            expandedSource: """
                class OpenService {
                }

                extension OpenService: FlightCore._FlightRegistrable {
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message:
                        "@Component requires a final class (or a struct). Mark 'OpenService' final.",
                    line: 2,
                    column: 7
                )
            ],
            macroSpecs: testMacros
        )
    }

    @Test("uninitialized stored property is rejected")
    func uninitializedStoredPropertyIsRejected() {
        // M-3: init(_flight:) assigns only injected properties; anything else
        // stored needs a default. Without this diagnostic the compile error
        // points inside the macro expansion.
        assertMacroExpansion(
            """
            @Component
            final class Tracer {
                let id: Int
            }
            """,
            expandedSource: """
                final class Tracer {
                    let id: Int
                }

                extension Tracer: FlightCore._FlightRegistrable {
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message:
                        "Stored property 'id' of a @Component type needs a default value — the generated init(_flight:) assigns only @Inject/@ConfigValue properties.",
                    line: 3,
                    column: 5
                )
            ],
            macroSpecs: testMacros
        )
    }

    @Test("transactional requires throws")
    func transactionalRequiresThrows() {
        assertMacroExpansion(
            """
            final class Quiet {
                @Transactional
                func run() {
                    work()
                }
            }
            """,
            expandedSource: """
                final class Quiet {
                    func run() {
                        work()
                    }
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message:
                        "@Transactional requires a throwing method — mark it 'throws' (rollback needs an error path).",
                    line: 3,
                    column: 10
                )
            ],
            macroSpecs: testMacros
        )
    }
}
