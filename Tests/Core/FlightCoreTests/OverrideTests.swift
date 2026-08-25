import Testing

@testable import FlightCore

private protocol Greeter: Sendable { func greet() -> String }
private struct RealGreeter: Greeter { func greet() -> String { "real" } }
private struct FakeGreeter: Greeter { func greet() -> String { "fake" } }

private struct RealModule: FlightModule {
    init() {}
    func configure(_ container: Container) throws {
        container.register((any Greeter).self, scope: .singleton) { _ in RealGreeter() }
    }
}

/// Overriding a registration is the mechanism that makes dependency injection
/// pay for itself in tests: run the real graph, swap one seam.
@Suite("Container.override")
struct OverrideTests {

    @Test("an override applied before the real registration wins")
    func overrideFirst() throws {
        let container = Container()
        container.override((any Greeter).self, scope: .singleton) { _ in FakeGreeter() }
        try RealModule().configure(container)
        try container.freeze()

        #expect(try container.resolve((any Greeter).self).greet() == "fake")
    }

    @Test("an override applied after the real registration also wins")
    func overrideSecond() throws {
        // Order-independence is the point: a test should not have to know
        // where in the module DAG its seam was registered.
        let container = Container()
        try RealModule().configure(container)
        container.override((any Greeter).self, scope: .singleton) { _ in FakeGreeter() }
        try container.freeze()

        #expect(try container.resolve((any Greeter).self).greet() == "fake")
    }

    @Test("overriding does not leave a duplicate to fail the freeze")
    func noDuplicate() throws {
        // Without the override path, registering a fake alongside the real
        // module throws BootstrapError.duplicateRegistration at freeze.
        let container = Container()
        try RealModule().configure(container)
        container.override((any Greeter).self, scope: .singleton) { _ in FakeGreeter() }
        #expect(throws: Never.self) { try container.freeze() }
    }

    @Test("a genuine duplicate still fails, override or not")
    func genuineDuplicateStillFails() throws {
        let container = Container()
        try RealModule().configure(container)
        try RealModule().configure(container)
        #expect(throws: (any Error).self) { try container.freeze() }
    }

    @Test("the last override wins")
    func lastWins() throws {
        let container = Container()
        container.override((any Greeter).self, scope: .singleton) { _ in RealGreeter() }
        container.override((any Greeter).self, scope: .singleton) { _ in FakeGreeter() }
        try container.freeze()

        #expect(try container.resolve((any Greeter).self).greet() == "fake")
    }

    @Test("an override appears once in the registration listing")
    func listedOnce() throws {
        let container = Container()
        try RealModule().configure(container)
        container.override((any Greeter).self, scope: .singleton) { _ in FakeGreeter() }
        try container.freeze()

        let greeters = container.allRegistrations().filter { $0.typeName.contains("Greeter") }
        #expect(greeters.count == 1)
        #expect(greeters.first?.sourceModule == "<override>")
    }

    @Test("qualifiers are part of the key")
    func qualifiers() throws {
        let container = Container()
        container.register((any Greeter).self, qualifier: "a", scope: .singleton) { _ in RealGreeter() }
        container.register((any Greeter).self, qualifier: "b", scope: .singleton) { _ in RealGreeter() }
        container.override((any Greeter).self, qualifier: "b", scope: .singleton) { _ in FakeGreeter() }
        try container.freeze()

        #expect(try container.resolve((any Greeter).self, qualifier: "a").greet() == "real")
        #expect(try container.resolve((any Greeter).self, qualifier: "b").greet() == "fake")
    }
}
