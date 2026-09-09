import Testing

@testable import FlightCore

@Suite("Bootstrap sequence and module health")
struct BootstrapTests {

    @Test("assemble collects services in the given order, cross-module values wired")
    func happyPath() throws {
        let logging = LoggingModule()
        let app = try Flight.assemble(
            configuration: Configuration(values: ["flight.test": "1"]),
            modules: [logging, FakeServerModule(sink: logging.sink)]
        )
        #expect(app.moduleOrder == ["LoggingModule", "FakeServerModule"])
        #expect(app.services.count == 1)
        #expect(app.services.first?.moduleName == "FakeServerModule")
    }

    @Test("every module reports .running after assembly")
    func healthRunning() throws {
        let logging = LoggingModule()
        let app = try Flight.assemble(
            configuration: Configuration(),
            modules: [logging, FakeServerModule(sink: logging.sink)])
        let statuses = app.health.statuses()
        #expect(statuses.count == 2)
        for status in statuses {
            guard case .running = status.health else {
                Issue.record("\(status.moduleName) expected .running, got \(status.health)")
                continue
            }
        }
    }

    @Test("a failing Service flips its module to .failed")
    func serviceFailureHealth() async throws {
        let app = try Flight.assemble(
            configuration: Configuration(), modules: [FailingServiceModule()])
        let entry = try #require(app.services.first)

        await #expect(throws: TestServiceError.self) {
            try await entry.service.run()
        }

        let status = try #require(
            app.health.statuses().first { $0.moduleName == "FailingServiceModule" }
        )
        guard case .failed = status.health else {
            Issue.record("expected .failed, got \(status.health)")
            return
        }
    }

    @Test("bootstrap returns immediately when no module owns a service")
    func serviceLessBootstrap() async throws {
        // Valid shape for one-shot CLI-style Flight apps.
        try await Flight.bootstrap(configuration: Configuration(), modules: [LoggingModule()])
    }

    @Test("a .endsApp service finishing shuts the app down gracefully")
    func oneShotServiceBootstrap() async throws {
        // Default (.failsApp) would make bootstrap throw serviceFinishedUnexpectedly here.
        try await Flight.bootstrap(configuration: Configuration(), modules: [OneShotModule()])
    }
}
