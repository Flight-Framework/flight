import Testing

@testable import FlightCore

@Suite("Container — two-phase model")
struct ContainerTests {

    @Test("singleton resolves to the same instance every time")
    func singletonIdentity() throws {
        let container = Container()
        container.register(Alpha.self, scope: .singleton) { _ in Alpha() }
        try container.freeze()

        let first: Alpha = try container.resolve()
        let second = try container.resolve(Alpha.self)
        #expect(first === second)
    }

    @Test("transient resolves to a fresh instance every time")
    func transientDistinct() throws {
        let container = Container()
        container.register(Alpha.self, scope: .transient) { _ in Alpha() }
        try container.freeze()

        let first = try container.resolve(Alpha.self)
        let second = try container.resolve(Alpha.self)
        #expect(first !== second)
    }

    @Test("factories resolve their own dependencies through the container")
    func dependencyResolution() throws {
        let container = Container()
        container.register(Alpha.self, scope: .singleton) { _ in Alpha() }
        container.register(Beta.self, scope: .singleton) { c in
            Beta(alpha: try c.resolve(Alpha.self))
        }
        try container.freeze()

        let beta = try container.resolve(Beta.self)
        let alpha = try container.resolve(Alpha.self)
        #expect(beta.alpha === alpha)
    }

    @Test("resolving an unregistered type throws notRegistered")
    func notRegistered() throws {
        let container = Container()
        container.register(Alpha.self, scope: .singleton) { _ in Alpha() }
        try container.freeze()

        #expect(throws: ResolutionError.self) {
            _ = try container.resolve(Gamma.self)
        }
    }

    @Test("singletons are constructed eagerly at freeze(), not on first resolve")
    func eagerSingletons() throws {
        let counter = InvocationCounter()
        let container = Container()
        container.register(Alpha.self, scope: .singleton) { _ in
            counter.increment()
            return Alpha()
        }
        #expect(counter.value == 0)
        try container.freeze()
        #expect(counter.value == 1)
        _ = try container.resolve(Alpha.self)
        _ = try container.resolve(Alpha.self)
        #expect(counter.value == 1)
    }

    @Test("transient factories do not run at freeze()")
    func lazyTransients() throws {
        let counter = InvocationCounter()
        let container = Container()
        container.register(Alpha.self, scope: .transient) { _ in
            counter.increment()
            return Alpha()
        }
        try container.freeze()
        #expect(counter.value == 0)
        _ = try container.resolve(Alpha.self)
        #expect(counter.value == 1)
    }

    @Test("qualifiers distinguish multiple components of one type")
    func qualifiers() throws {
        let container = Container()
        container.register(Alpha.self, qualifier: "primary", scope: .singleton) { _ in Alpha() }
        container.register(Alpha.self, qualifier: "replica", scope: .singleton) { _ in Alpha() }
        try container.freeze()

        let primary = try container.resolve(Alpha.self, qualifier: "primary")
        let replica = try container.resolve(Alpha.self, qualifier: "replica")
        #expect(primary !== replica)
        #expect(primary === (try container.resolve(Alpha.self, qualifier: "primary")))

        // The unqualified key is a distinct registration; absent one, this
        // is notRegistered — qualifiers never fall back silently.
        #expect(throws: ResolutionError.self) {
            _ = try container.resolve(Alpha.self)
        }
    }

    @Test("resolving a .scoped component without a scope throws scopeRequired")
    func scopedNeedsScope() throws {
        let container = Container()
        container.register(Gamma.self, scope: .scoped) { _ in Gamma() }
        try container.freeze()

        do {
            _ = try container.resolve(Gamma.self)
            Issue.record("expected scopeRequired")
        } catch let error as ResolutionError {
            guard case .scopeRequired = error else {
                Issue.record("expected scopeRequired, got \(error)")
                return
            }
        }
    }

    @Test("post-freeze resolution is safe under concurrency (smoke)")
    func concurrentResolve() async throws {
        let container = Container()
        container.register(Alpha.self, scope: .singleton) { _ in Alpha() }
        container.register(Beta.self, scope: .transient) { c in
            Beta(alpha: try c.resolve(Alpha.self))
        }
        try container.freeze()
        let canonical = try container.resolve(Alpha.self)

        try await withThrowingTaskGroup(of: Bool.self) { group in
            for _ in 0..<200 {
                group.addTask {
                    let alpha = try container.resolve(Alpha.self)
                    let beta = try container.resolve(Beta.self)
                    return alpha === canonical && beta.alpha === canonical
                }
            }
            for try await ok in group {
                #expect(ok)
            }
        }
    }
}
