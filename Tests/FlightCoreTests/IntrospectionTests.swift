import Testing

@testable import FlightCore

@Suite("Introspection")
struct IntrospectionTests {

    @Test("allRegistrations reflects registration order, scope, and qualifier")
    func descriptors() throws {
        let container = Container()
        container.register(Alpha.self, scope: .singleton) { _ in Alpha() }
        container.register(Beta.self, scope: .transient) { c in
            Beta(alpha: try c.resolve(Alpha.self))
        }
        container.register(Gamma.self, qualifier: "special", scope: .scoped) { _ in Gamma() }
        try container.freeze()

        let descriptors = container.allRegistrations()
        #expect(descriptors.count == 3)

        #expect(descriptors[0].typeName.contains("Alpha"))
        #expect(descriptors[0].scope == .singleton)
        #expect(descriptors[0].qualifier == nil)
        // Hand registrations default to the generic layer.
        #expect(descriptors[0].stereotype == .component)

        #expect(descriptors[1].typeName.contains("Beta"))
        #expect(descriptors[1].scope == .transient)

        #expect(descriptors[2].typeName.contains("Gamma"))
        #expect(descriptors[2].scope == .scoped)
        #expect(descriptors[2].qualifier == "special")
    }

    @Test("sourceModule is stamped from the configuring module")
    func sourceModuleStamping() throws {
        let app = try Flight.assemble(
            configuration: Configuration(), modules: [FakeServerModule.self])
        let descriptors = app.container.allRegistrations()

        let sink = try #require(descriptors.first { $0.typeName.contains("TestLogSink") })
        #expect(sink.sourceModule == "LoggingModule")

        let server = try #require(descriptors.first { $0.typeName.contains("FakeServer") })
        #expect(server.sourceModule == "FakeServerModule")

        // Bootstrap's own registration of Configuration is attributed to
        // "<direct>" — it belongs to no module.
        let config = try #require(descriptors.first { $0.typeName.contains("Configuration") })
        #expect(config.sourceModule == "<direct>")
    }
}
