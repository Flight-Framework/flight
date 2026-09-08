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

}
