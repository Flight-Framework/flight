import Testing

@testable import FlightCore

// Mutually referential singleton pair for runtime cycle checks.
private final class Ouro: @unchecked Sendable {
    let other: Boros
    init(other: Boros) { self.other = other }
}
private final class Boros: @unchecked Sendable {
    let other: Ouro
    init(other: Ouro) { self.other = other }
}

@Suite("Cycle detection")
struct CycleDetectionTests {

    @Test("singleton cycle surfaces at freeze() with the full chain named")
    func singletonCycleAtFreeze() {
        let container = Container()
        container.register(Ouro.self, scope: .singleton) { c in
            Ouro(other: try c.resolve(Boros.self))
        }
        container.register(Boros.self, scope: .singleton) { c in
            Boros(other: try c.resolve(Ouro.self))
        }

        do {
            try container.freeze()
            Issue.record("expected circularDependency at freeze()")
        } catch let error as ResolutionError {
            guard case .circularDependency(let chain) = error else {
                Issue.record("expected circularDependency, got \(error)")
                return
            }
            #expect(chain.count >= 3)
            #expect(chain.contains { $0.contains("Ouro") })
            #expect(chain.contains { $0.contains("Boros") })
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test("transient cycle surfaces at resolve() post-freeze")
    func transientCyclePostFreeze() throws {
        let container = Container()
        container.register(Ouro.self, scope: .transient) { c in
            Ouro(other: try c.resolve(Boros.self))
        }
        container.register(Boros.self, scope: .transient) { c in
            Boros(other: try c.resolve(Ouro.self))
        }
        try container.freeze()  // no singletons — freeze constructs nothing

        do {
            _ = try container.resolve(Ouro.self)
            Issue.record("expected circularDependency")
        } catch let error as ResolutionError {
            guard case .circularDependency = error else {
                Issue.record("expected circularDependency, got \(error)")
                return
            }
        }
    }

    @Test("module dependency cycle is rejected with the chain named")
    func moduleCycle() {
        do {
            _ = try Flight.resolveModuleOrder([CycleModX.self])
            Issue.record("expected ModuleGraphError.cycle")
        } catch let error as ModuleGraphError {
            guard case .cycle(let names) = error else {
                Issue.record("expected .cycle")
                return
            }
            #expect(names.contains("CycleModX"))
            #expect(names.contains("CycleModY"))
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }
}
