import FlightCore
import Testing

@Suite("Constructor injection")
struct ConstructorInjectionTests {

    @Test("a component builds from its dependencies, with no container")
    func buildsWithoutAContainer() throws {
        // The point of the whole migration, in one line: no registration, no
        // freeze, no override registry. A struct would get this from
        // memberwise synthesis, except that `@Component`'s `init(_flight:)`
        // suppresses it — which is why it is generated.
        let service = CountingService(clock: FixedClock(now: 7))
        #expect(service.clock.now() == 7)
    }

    @Test("the same instance passed twice is shared, by construction")
    func sharingIsByConstruction() throws {
        // What a scope's memo table used to do. Under constructor injection
        // there is nothing to memoize: the caller has the value and passes
        // it, so sharing is visible at the call site instead of being a
        // property of a lifetime nobody can see.
        let clock = FixedClock(now: 3)
        let first = CountingService(clock: clock)
        let second = CountingService(clock: clock)
        #expect(first.clock as? FixedClock === second.clock as? FixedClock)
    }

    @Test("a hand-written initializer is not redeclared")
    func handWrittenInitializerWins() throws {
        // `Authentication` is the live case in the framework: an @Inject
        // property plus a hand-written init(validator:) for manual wiring.
        // Generating a second with the same labels would be a redeclaration
        // error inside an expansion the author cannot see.
        let existing = HandWritten(dependency: FixedClock(now: 1))
        #expect(existing.marker == "hand-written")
    }
}

/// A clock with a fixed answer, for the tests above.
final class FixedClock: ClockReading {
    let value: Int
    init(now: Int) { self.value = now }
    func now() -> Int { value }
}

protocol ClockReading: Sendable, AnyObject {
    func now() -> Int
}

@Component
struct CountingService: Sendable {
    @Inject var clock: any ClockReading
}

@Component
struct HandWritten: Sendable {
    @Inject var dependency: any ClockReading
    var marker: String = ""

    /// Deliberately the signature the macro would otherwise generate.
    init(dependency: any ClockReading) {
        self.dependency = dependency
        self.marker = "hand-written"
    }
}
