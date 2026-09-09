import Testing

@testable import FlightCore

/// The shape D11 moves modules to: a module takes what it needs as
/// initializer parameters and holds what it provides as stored properties.
///
/// `Flight.assemble(configuration:modules:)`'s type-based overload cannot
/// express that — it instantiates modules itself, so every module has to be
/// constructible with no arguments, which is why one reads configuration
/// through the container instead of taking it. The instance overload takes
/// what a caller already built.
@Suite("A module that owns what it provides")
struct ComposedModuleTests {

    @Test("a module can take configuration in its initializer")
    func takesItsInputs() throws {
        let configuration = Configuration(values: ["greeting.text": "hello"])
        // The component the module built, reachable as a property: no
        // registration, no lookup by type, two field loads.
        let module = try GreetingModule(configuration: configuration)
        #expect(module.greeter.text == "hello")
    }

    @Test("a module's components are reachable without resolving them")
    func componentsAreProperties() throws {
        let configuration = Configuration(values: ["greeting.text": "hi"])
        let module = try GreetingModule(configuration: configuration)
        // Constructed and asserted without a container at all, which is the
        // point: a module is a value.
        #expect(module.greeter.text == "hi")
    }

    @Test("dependency order is the caller's, because the DAG moved to the build")
    func orderIsTheCallers() throws {
        // The one thing this signature cannot check. The type-based overload
        // sorts by `dependencies`; given instances there is nothing left to
        // sort by, so a generated root supplies them already ordered.
        let configuration = Configuration(values: ["greeting.text": "ordered"])
        let app = try Flight.assemble(
            configuration: configuration,
            modules: [try GreetingModule(configuration: configuration), TrailingModule()])
        #expect(app.moduleOrder == ["GreetingModule", "TrailingModule"])
    }
}

/// A greeting, built by its module rather than registered by it.
struct Salutation: Sendable {
    let text: String
}

struct GreetingModule: FlightModule {
    let greeter: Salutation

    init(configuration: Configuration) throws {
        self.greeter = Salutation(text: try configuration.get("greeting.text", as: String.self))
    }

}

struct TrailingModule: FlightModule {}
