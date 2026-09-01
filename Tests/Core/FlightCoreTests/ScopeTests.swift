import Testing

@testable import FlightCore

@Suite("Scope")
struct ScopeTests {

    private func makeContainer() throws -> Container {
        let container = Container()
        container.register(Gamma.self, scope: .scoped) { _ in Gamma() }
        container.register(Alpha.self, scope: .singleton) { _ in Alpha() }
        try container.freeze()
        return container
    }

    @Test("one instance per scope; distinct across scopes")
    func scopedIdentity() throws {
        let container = try makeContainer()

        try container.withScope { scopeOne in
            let a = try container.resolve(Gamma.self, in: scopeOne)
            let b = try container.resolve(Gamma.self, in: scopeOne)
            #expect(a === b)

            try container.withScope { scopeTwo in
                let c = try container.resolve(Gamma.self, in: scopeTwo)
                #expect(a !== c)
            }
        }
    }

    @Test("singleton components resolved through a scope are still the singleton")
    func singletonThroughScope() throws {
        let container = try makeContainer()
        let canonical = try container.resolve(Alpha.self)
        try container.withScope { scope in
            let viaScope = try container.resolve(Alpha.self, in: scope)
            #expect(viaScope === canonical)
        }
    }

    @Test("scoped instances are released when the scope body returns")
    func scopedRelease() throws {
        let container = try makeContainer()
        weak var leaked: Gamma?
        try container.withScope { scope in
            let instance = try container.resolve(Gamma.self, in: scope)
            leaked = instance
            #expect(leaked != nil)
        }
        #expect(leaked == nil, "scope end should make instances eligible for cleanup")
    }

    @Test("async withScope variant behaves identically")
    func asyncWithScope() async throws {
        let container = try makeContainer()
        weak var leaked: Gamma?
        try await container.withScope { scope in
            await Task.yield()
            let instance = try container.resolve(Gamma.self, in: scope)
            leaked = instance
        }
        #expect(leaked == nil)
    }

    @Test("using a scope after its body returned throws ScopeError.closed")
    func escapedScope() throws {
        let container = try makeContainer()
        var escaped: Scope?
        container.withScope { scope in
            escaped = scope
        }
        #expect(throws: ScopeError.self) {
            _ = try container.resolve(Gamma.self, in: escaped!)
        }
    }
}

// MARK: - Ambient scope

/// A scoped component depending on another scoped component — the shape Flight Data's
/// scope-bound connections need, and the case that surfaced
/// the gap: factories receive only the Container, so without an ambient
/// scope a scoped dependency was unreachable from any factory.
@Suite("Ambient scope — scoped components as dependencies")
struct ActiveScopeTests {

    /// Delta depends on Gamma; both scoped. Epsilon depends on Gamma; transient.
    final class Delta: Sendable {
        let gamma: Gamma
        init(gamma: Gamma) { self.gamma = gamma }
    }

    final class Epsilon: Sendable {
        let gamma: Gamma
        init(gamma: Gamma) { self.gamma = gamma }
    }

    private func makeContainer() throws -> Container {
        let container = Container()
        container.register(Gamma.self, scope: .scoped) { _ in Gamma() }
        container.register(Delta.self, scope: .scoped) { c in
            Delta(gamma: try c.resolveInActiveScope(Gamma.self))
        }
        container.register(Epsilon.self, scope: .transient) { c in
            Epsilon(gamma: try c.resolveInActiveScope(Gamma.self))
        }
        try container.freeze()
        return container
    }

    @Test("a scoped component's factory reaches the scope's instance of its dependency")
    func scopedDependsOnScoped() throws {
        let container = try makeContainer()
        try container.withScope { scope in
            let delta = try container.resolve(Delta.self, in: scope)
            let gamma = try container.resolve(Gamma.self, in: scope)
            #expect(delta.gamma === gamma, "both resolutions must land in the same scope")
        }
    }

    @Test("distinct scopes yield distinct dependency instances")
    func scopedDependencyIsolation() throws {
        let container = try makeContainer()
        try container.withScope { scopeOne in
            let one = try container.resolve(Delta.self, in: scopeOne)
            try container.withScope { scopeTwo in
                let two = try container.resolve(Delta.self, in: scopeTwo)
                #expect(one.gamma !== two.gamma)
            }
        }
    }

    @Test("a transient resolved in a scope shares that scope's dependencies")
    func transientDependsOnScoped() throws {
        let container = try makeContainer()
        try container.withScope { scope in
            let a = try container.resolve(Epsilon.self, in: scope)
            let b = try container.resolve(Epsilon.self, in: scope)
            #expect(a !== b, "transient: a fresh instance per resolve")
            #expect(a.gamma === b.gamma, "…but both see the scope's one Gamma")
        }
    }

    @Test("resolveInActiveScope outside any scoped resolution throws noActiveScope")
    func noAmbientScope() throws {
        let container = try makeContainer()
        #expect(throws: ResolutionError.self) {
            _ = try container.resolveInActiveScope(Gamma.self)
        }
    }

    @Test("a singleton depending on a scoped component fails loudly at freeze (captive dependency)")
    func captiveDependencyFailsAtFreeze() throws {
        final class Captor: Sendable {
            let gamma: Gamma
            init(gamma: Gamma) { self.gamma = gamma }
        }
        let container = Container()
        container.register(Gamma.self, scope: .scoped) { _ in Gamma() }
        container.register(Captor.self, scope: .singleton) { c in
            Captor(gamma: try c.resolveInActiveScope(Gamma.self))
        }
        #expect(throws: ResolutionError.self) {
            try container.freeze()
        }
    }

    @Test("the ambient scope does not leak outside the resolution")
    func ambientScopeIsBounded() throws {
        let container = try makeContainer()
        try container.withScope { scope in
            _ = try container.resolve(Delta.self, in: scope)
            #expect(Scope.active == nil, "binding must end with the resolve call")
        }
    }
}

// MARK: - Ambient fallback

/// Plain `resolve` — the call `@Inject` expands to — rides the ambient
/// scope for `.scoped` registrations. This is the general form of delta 11:
/// `resolveInActiveScope` made scoped dependencies *reachable* from
/// hand-written factories; the fallback makes them reachable from the
/// macro-generated path too, so `@Service(scope: .scoped)` can `@Inject`
/// a `.scoped` repository. The captive-dependency guarantee is untouched —
/// no ambient scope (in particular: eager singleton construction at
/// `freeze()`) still fails loudly.
@Suite("Ambient fallback — plain resolve rides the active scope")
struct AmbientFallbackTests {

    /// Depends on Gamma through PLAIN resolve — exactly the assignment an
    /// `@Inject` property's generated `init(_flight:)` produces.
    final class Zeta: Sendable {
        let gamma: Gamma
        init(gamma: Gamma) { self.gamma = gamma }
    }

    private func makeContainer() throws -> Container {
        let container = Container()
        container.register(Gamma.self, scope: .scoped) { _ in Gamma() }
        container.register(Zeta.self, scope: .scoped) { c in
            Zeta(gamma: try c.resolve(Gamma.self))  // plain resolve — the @Inject shape
        }
        try container.freeze()
        return container
    }

    @Test("plain resolve of a scoped component inside a scoped resolution lands in that scope")
    func injectShape() throws {
        let container = try makeContainer()
        try container.withScope { scope in
            let zeta = try container.resolve(Zeta.self, in: scope)
            let gamma = try container.resolve(Gamma.self, in: scope)
            #expect(zeta.gamma === gamma, "the fallback must land in the binding scope")
        }
    }

    @Test("distinct scopes get distinct instances through the fallback")
    func fallbackIsolation() throws {
        let container = try makeContainer()
        try container.withScope { one in
            let a = try container.resolve(Zeta.self, in: one)
            try container.withScope { two in
                let b = try container.resolve(Zeta.self, in: two)
                #expect(a !== b)
                #expect(a.gamma !== b.gamma)
            }
        }
    }

    @Test("plain resolve of a scoped component with no ambient scope still throws scopeRequired")
    func noScopeStillLoud() throws {
        let container = try makeContainer()
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

    @Test(
        "a singleton factory plain-resolving a scoped component still fails at freeze (captive dependency)"
    )
    func captiveStillCaught() throws {
        final class Captor: Sendable {
            let gamma: Gamma
            init(gamma: Gamma) { self.gamma = gamma }
        }
        let container = Container()
        container.register(Gamma.self, scope: .scoped) { _ in Gamma() }
        container.register(Captor.self, scope: .singleton) { c in
            Captor(gamma: try c.resolve(Gamma.self))
        }
        #expect(throws: ResolutionError.self) {
            try container.freeze()
        }
    }
}
