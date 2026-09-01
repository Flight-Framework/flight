// End-to-end: the macros expand for real (compiler plugin runs during this
// target's build) and the expansions are exercised against a live container.
// Textual expansion correctness lives in FlightCoreMacroTests; this file is
// the "does the generated code actually behave" layer.
//
// If macro compilation is ever broken by swift-syntax churn, this file is the
// one to comment out while fixing FlightCoreMacrosImpl — nothing else in
// FlightCoreTests uses macros.

import Logging
import Synchronization
import Testing

@testable import FlightCore

// MARK: - Components under test

@Component
final class MacroClock: Sendable {
    func now() -> Int { 42 }
}

@Component
final class MacroConsumer: Sendable {
    @Inject let clock: MacroClock
}

@Component(scope: .transient)
final class MacroTransient: Sendable {}

@Repository
final class MacroRepository: Sendable {
    func fetch() -> String { "row" }
}

@Service
final class MacroService: Sendable {
    @Inject let repository: MacroRepository
}

@Component
final class MacroConfigured: Sendable {
    @ConfigValue("server.port") let port: Int
}

@Component
final class MacroDefaulted: Sendable {
    @ConfigValue("server.port") let port: Int
    @ConfigValue("server.workers", default: 4) let workers: Int
}

@Component
struct MacroQualified: Sendable {
    @Inject("primary") let primary: MacroClock
    @Inject("replica") let replica: MacroClock
}

// MARK: - Recording transaction coordinator

final class RecordingCoordinator: FlightTransactionCoordinator, Sendable {
    private let log = Mutex<[String]>([])
    var events: [String] { log.withLock { $0 } }

    func begin() throws -> FlightTransactionToken {
        log.withLock { $0.append("begin") }
        return FlightTransactionToken(id: 7)
    }
    func commit(_ token: FlightTransactionToken) throws {
        log.withLock { $0.append("commit#\(token.id)") }
    }
    func rollback(_ token: FlightTransactionToken) {
        log.withLock { $0.append("rollback#\(token.id)") }
    }
}

/// Async-native counterpart. Distinct token id so tests can see
/// which coordinator issued the frame.
final class RecordingAsyncCoordinator: FlightAsyncTransactionCoordinator, Sendable {
    private let log = Mutex<[String]>([])
    var events: [String] { log.withLock { $0 } }

    func begin() async throws -> FlightTransactionToken {
        log.withLock { $0.append("begin") }
        return FlightTransactionToken(id: 9)
    }
    func commit(_ token: FlightTransactionToken) async throws {
        log.withLock { $0.append("commit#\(token.id)") }
    }
    func rollback(_ token: FlightTransactionToken) async {
        log.withLock { $0.append("rollback#\(token.id)") }
    }
}

enum LedgerError: Error { case insufficient }

final class MacroLedger: Sendable {
    @Transactional
    func post(_ amount: Int) throws -> Int {
        if amount < 0 { throw LedgerError.insufficient }
        return amount * 2
    }

    @Transactional
    func postAsync(_ amount: Int) async throws -> Int {
        await Task.yield()
        if amount < 0 { throw LedgerError.insufficient }
        return amount * 2
    }
}

// MARK: - Tests

@Suite("Macro integration — generated code against a live container")
struct MacroIntegrationTests {

    @Test("@Component registration + @Inject resolution round-trip")
    func componentRoundTrip() throws {
        let container = Container()
        try MacroClock._flightRegister(container)
        try MacroConsumer._flightRegister(container)
        try container.freeze()

        let consumer = try container.resolve(MacroConsumer.self)
        let clock = try container.resolve(MacroClock.self)
        #expect(consumer.clock === clock)
        #expect(consumer.clock.now() == 42)
    }

    @Test("@Component conforms the type to _FlightRegistrable")
    func registrableConformance() {
        let registrable: any _FlightRegistrable.Type = MacroClock.self
        #expect(ObjectIdentifier(registrable) == ObjectIdentifier(MacroClock.self))
    }

    @Test("@Service/@Repository register like @Component, tagged with their layer")
    func stereotypes() throws {
        let container = Container()
        try MacroClock._flightRegister(container)
        try MacroRepository._flightRegister(container)
        try MacroService._flightRegister(container)
        try container.freeze()

        // Same wiring semantics as @Component — @Inject across stereotypes.
        let service = try container.resolve(MacroService.self)
        let repository = try container.resolve(MacroRepository.self)
        #expect(service.repository === repository)
        #expect(service.repository.fetch() == "row")

        // The tag is introspection metadata, not identity.
        let byName = Dictionary(
            uniqueKeysWithValues: container.allRegistrations().map { ($0.typeName, $0.stereotype) }
        )
        #expect(byName.first { $0.key.contains("MacroClock") }?.value == .component)
        #expect(byName.first { $0.key.contains("MacroRepository") }?.value == .repository)
        #expect(byName.first { $0.key.contains("MacroService") }?.value == .service)
    }

    @Test("@Component(scope: .transient) registers transient")
    func transientScope() throws {
        let container = Container()
        try MacroTransient._flightRegister(container)
        try container.freeze()

        let first = try container.resolve(MacroTransient.self)
        let second = try container.resolve(MacroTransient.self)
        #expect(first !== second)
    }

    @Test("@ConfigValue resolves through the Configuration component")
    func configValue() throws {
        let container = Container()
        container.register(Configuration.self, scope: .singleton) { _ in
            Configuration(values: ["server.port": "9090"])
        }
        try MacroConfigured._flightRegister(container)
        try container.freeze()

        let configured = try container.resolve(MacroConfigured.self)
        #expect(configured.port == 9090)
    }

    @Test("@ConfigValue default: applies on absence, never on malformed values")
    func configValueDefault() throws {
        // Absent key → default.
        let container = Container()
        container.register(Configuration.self, scope: .singleton) { _ in
            Configuration(values: ["server.port": "9090"])  // no server.workers
        }
        try MacroDefaulted._flightRegister(container)
        try container.freeze()
        let defaulted = try container.resolve(MacroDefaulted.self)
        #expect(defaulted.port == 9090)
        #expect(defaulted.workers == 4)

        // Present-but-malformed → the expansion throws (surfacing at eager
        // singleton construction), rather than silently taking the default.
        let broken = Container()
        broken.register(Configuration.self, scope: .singleton) { _ in
            Configuration(values: ["server.port": "9090", "server.workers": "many"])
        }
        try MacroDefaulted._flightRegister(broken)
        #expect(throws: (any Error).self) {
            try broken.freeze()
        }
    }

    @Test("@Inject qualifiers resolve distinct components of one type")
    func qualifiedInjection() throws {
        let container = Container()
        // M-2 : the generated init(_flight:) suppresses the
        // implicit init(), so hand-construction goes through it too.
        container.register(MacroClock.self, qualifier: "primary", scope: .singleton) { c in
            try MacroClock(_flight: c)
        }
        container.register(MacroClock.self, qualifier: "replica", scope: .singleton) { c in
            try MacroClock(_flight: c)
        }
        try MacroQualified._flightRegister(container)
        try container.freeze()

        let qualified = try container.resolve(MacroQualified.self)
        #expect(qualified.primary !== qualified.replica)
    }

    @Test("@Transactional commits on success (sync)")
    func transactionalCommit() throws {
        let coordinator = RecordingCoordinator()
        try FlightTransactions.$coordinator.withValue(coordinator) {
            let result = try MacroLedger().post(10)
            #expect(result == 20)
        }
        #expect(coordinator.events == ["begin", "commit#7"])
    }

    @Test("@Transactional rolls back and rethrows on error (sync)")
    func transactionalRollback() {
        let coordinator = RecordingCoordinator()
        FlightTransactions.$coordinator.withValue(coordinator) {
            #expect(throws: LedgerError.self) {
                _ = try MacroLedger().post(-1)
            }
        }
        #expect(coordinator.events == ["begin", "rollback#7"])
    }

    @Test("@Transactional commits on success (async)")
    func transactionalAsyncCommit() async throws {
        let coordinator = RecordingCoordinator()
        try await FlightTransactions.$coordinator.withValue(coordinator) {
            let result = try await MacroLedger().postAsync(21)
            #expect(result == 42)
        }
        #expect(coordinator.events == ["begin", "commit#7"])
    }

    @Test("@Transactional rolls back and rethrows on error (async)")
    func transactionalAsyncRollback() async {
        let coordinator = RecordingCoordinator()
        await FlightTransactions.$coordinator.withValue(coordinator) {
            await #expect(throws: LedgerError.self) {
                _ = try await MacroLedger().postAsync(-1)
            }
        }
        #expect(coordinator.events == ["begin", "rollback#7"])
    }

    // MARK: Async-native coordination
    //
    // The two tests above double as the FALLBACK proof: they bind only the
    // sync coordinator, and the async method's preferring-async expansion
    // lands there when no async-native coordinator is bound.

    @Test("an async @Transactional method prefers the async-native coordinator")
    func transactionalAsyncPrefersAsyncCoordinator() async throws {
        let sync = RecordingCoordinator()
        let asyncNative = RecordingAsyncCoordinator()
        try await FlightTransactions.$coordinator.withValue(sync) {
            try await FlightTransactions.$asyncCoordinator.withValue(asyncNative) {
                let result = try await MacroLedger().postAsync(21)
                #expect(result == 42)
            }
        }
        #expect(asyncNative.events == ["begin", "commit#9"])
        #expect(
            sync.events.isEmpty,
            "sync coordinator must be untouched when an async-native one is bound")
    }

    @Test("async rollback rides the async-native coordinator too")
    func transactionalAsyncRollbackPrefersAsyncCoordinator() async {
        let sync = RecordingCoordinator()
        let asyncNative = RecordingAsyncCoordinator()
        await FlightTransactions.$coordinator.withValue(sync) {
            await FlightTransactions.$asyncCoordinator.withValue(asyncNative) {
                await #expect(throws: LedgerError.self) {
                    _ = try await MacroLedger().postAsync(-1)
                }
            }
        }
        #expect(asyncNative.events == ["begin", "rollback#9"])
        #expect(sync.events.isEmpty)
    }

    @Test("a sync @Transactional method uses the sync coordinator even with an async one bound")
    func transactionalSyncIgnoresAsyncCoordinator() throws {
        let sync = RecordingCoordinator()
        let asyncNative = RecordingAsyncCoordinator()
        try FlightTransactions.$coordinator.withValue(sync) {
            try FlightTransactions.$asyncCoordinator.withValue(asyncNative) {
                let result = try MacroLedger().post(21)
                #expect(result == 42)
            }
        }
        #expect(sync.events == ["begin", "commit#7"])
        #expect(asyncNative.events.isEmpty)
    }
}

/// The no-op coordinator says so.
///
/// This is the default `@Transactional` reaches when nothing bound a real
/// coordinator, and the failure it produces is invisible: the method runs,
/// the writes land, the tests pass, and the first body that throws halfway
/// leaves the writes before the throw behind. Found in an application whose
/// web handlers never bound one — every "transactional" service method there
/// had been a no-op since the day it was written.
@Suite("The no-op coordinator announces itself", .serialized)
struct NoopCoordinatorWarningTests {

    @Test("beginning a transaction on it warns, once, however many times it is called")
    func warnsOnce() throws {
        NoopTransactionCoordinator.resetWarningForTesting()

        let coordinator = NoopTransactionCoordinator()
        _ = try coordinator.begin()
        _ = try coordinator.begin()
        _ = try coordinator.begin()

        // Once per process: repeating it per call would be noise on a busy
        // server, and noise is how a real warning gets filtered out.
        #expect(NoopTransactionCoordinator.warningCountForTesting == 1)
    }

    @Test("a second coordinator does not warn again — the flag is per process")
    func flagIsProcessWide() throws {
        NoopTransactionCoordinator.resetWarningForTesting()

        _ = try NoopTransactionCoordinator().begin()
        _ = try NoopTransactionCoordinator().begin()

        #expect(NoopTransactionCoordinator.warningCountForTesting == 1)
    }

    @Test("the message names the general fix before the Flight Data one")
    func messageIsActionable() {
        let message = NoopTransactionCoordinator.warningMessage
        // Core owns the shape of transaction coordination and never a
        // datasource, so the remedy it prescribes has to work for a
        // coordinator that is not Flight Data's — this used to name only
        // Postgres helpers, which is wrong advice for anyone else and the
        // one place Core knew what database you were using.
        #expect(message.contains("FlightTransactions.coordinator"))
        #expect(message.contains("your data layer"))
        // Flight Data's helpers still named, as the concrete example.
        #expect(message.contains("withPostgresScope"))
        #expect(message.contains("withPostgresTransactions"))
        // And says what actually happened, not just what to do about it.
        #expect(message.contains("not atomic"))
    }

    @Test("commit and rollback stay silent — one warning per process, at begin")
    func onlyBeginWarns() throws {
        NoopTransactionCoordinator.resetWarningForTesting()

        let coordinator = NoopTransactionCoordinator()
        let token = FlightTransactionToken(id: 7)
        try coordinator.commit(token)
        coordinator.rollback(token)

        #expect(NoopTransactionCoordinator.warningCountForTesting == 0)
    }
}
