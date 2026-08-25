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

/// The container resolves to itself.
///
/// Needed by components that outlive every scope and must open one of their
/// own — a channel that lives as long as a browser tab, a scheduled job that
/// runs on its own clock. Before this, the gateway pattern that does it could
/// only be built by hand-writing a factory per gateway.
@Suite("Container resolves to itself")
struct ContainerSelfResolutionTests {

    @Test("resolve(Container.self) is the container")
    func identity() throws {
        let container = Container()
        try container.freeze()

        #expect(try container.resolve(Container.self) === container)
    }

    @Test("a component can be injected with it")
    func injectable() throws {
        // The shape a gateway has: a singleton holding the container so it
        // can open a scope per call later.
        struct Gateway: Sendable {
            let container: Container
        }
        let container = Container()
        container.register(Gateway.self, scope: .singleton) { c in
            Gateway(container: try c.resolve(Container.self))
        }
        try container.freeze()

        #expect(try container.resolve(Gateway.self).container === container)
    }

    @Test("two containers resolve to themselves, not to each other")
    func notGlobal() throws {
        let first = Container()
        let second = Container()
        try first.freeze()
        try second.freeze()

        #expect(try first.resolve(Container.self) === first)
        #expect(try second.resolve(Container.self) === second)
    }

    @Test("it is not in the singleton map, so there is no cycle to leak")
    func noRetainCycle() throws {
        weak var weakContainer: Container?
        do {
            let container = Container()
            container.register(Alpha.self, scope: .singleton) { _ in Alpha() }
            try container.freeze()
            // Resolve it, which is what would populate a singleton slot if
            // this were an ordinary registration.
            _ = try container.resolve(Container.self)
            weakContainer = container
            #expect(weakContainer != nil)
        }
        // Storing self in `frozen.singletons` would keep this alive forever;
        // a suite building a thousand containers would leak a thousand.
        #expect(weakContainer == nil)
    }

    @Test("a qualified Container is an ordinary lookup, and still absent")
    func qualifierIsNotSpecialCased() throws {
        let container = Container()
        try container.freeze()

        #expect(throws: ResolutionError.self) {
            try container.resolve(Container.self, qualifier: "other")
        }
    }
}

/// The precedence question the fallback answers.
///
/// Hand-registering `Container.self { c in c }` was the workaround before the
/// container resolved to itself, and applications did it — Actuator's own
/// suite has a test for an app that does. So self-resolution answers only
/// when the lookup misses; a registration that is there still wins.
@Suite("Container self-resolution defers to a registration")
struct ContainerSelfResolutionPrecedenceTests {

    @Test("the old hand-registration still wins, and still resolves")
    func registrationWins() throws {
        let container = Container()
        container.register(Container.self, scope: .singleton) { c in c }
        try container.freeze()

        #expect(try container.resolve(Container.self) === container)
    }

    @Test("a registration producing a different container is honoured, not shadowed")
    func differentContainerIsNotShadowed() throws {
        // Contrived, but it is the case that distinguishes a fallback from an
        // interception: whoever registers this meant it, and silently
        // returning the outer container instead would be the same class of
        // bug as configuration nobody reads.
        let other = Container()
        try other.freeze()

        let container = Container()
        container.register(Container.self, scope: .singleton) { _ in other }
        try container.freeze()

        #expect(try container.resolve(Container.self) === other)
    }
}
