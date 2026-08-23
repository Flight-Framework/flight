import Testing

@testable import FlightCore

@Suite("Module DAG resolution")
struct ModuleGraphTests {

    private func names(_ modules: [any FlightModule.Type]) -> [String] {
        modules.map { $0.moduleName }
    }

    @Test("dependencies precede dependents")
    func dependenciesFirst() throws {
        let order = names(
            try Flight.resolveModuleOrder([FakeServerModule.self, LoggingModule.self]))
        let logging = try #require(order.firstIndex(of: "LoggingModule"))
        let server = try #require(order.firstIndex(of: "FakeServerModule"))
        #expect(logging < server)
    }

    @Test("diamond resolves once per module, dependencies first")
    func diamond() throws {
        let order = names(try Flight.resolveModuleOrder([ModD.self]))
        #expect(order == ["ModA", "ModB", "ModC", "ModD"])
    }

    @Test("transitive dependencies are auto-included")
    func transitiveInclusion() throws {
        // Only ModD is listed; A, B, C arrive via its declared dependencies.
        let order = names(try Flight.resolveModuleOrder([ModD.self]))
        #expect(Set(order) == ["ModA", "ModB", "ModC", "ModD"])
    }

    @Test("order is deterministic across calls and input-order stable")
    func determinism() throws {
        let first = names(try Flight.resolveModuleOrder([ModD.self, LoggingModule.self]))
        for _ in 0..<10 {
            let again = names(try Flight.resolveModuleOrder([ModD.self, LoggingModule.self]))
            #expect(again == first)
        }
        // Modules are visited in the order given: D's subtree fully precedes
        // the later-listed LoggingModule.
        #expect(first == ["ModA", "ModB", "ModC", "ModD", "LoggingModule"])
    }

    @Test("duplicate listings are collapsed")
    func duplicates() throws {
        let order = names(try Flight.resolveModuleOrder([ModA.self, ModA.self, ModB.self]))
        #expect(order == ["ModA", "ModB"])
    }
}
