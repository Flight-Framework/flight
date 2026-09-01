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
}
