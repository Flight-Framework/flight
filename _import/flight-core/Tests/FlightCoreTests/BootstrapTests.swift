import Testing

@testable import FlightCore

@Suite("Bootstrap sequence and module health")
struct BootstrapTests {

    @Test("assemble wires modules in DAG order and freezes the container")
    func happyPath() throws {
        let app = try Flight.assemble(
            configuration: Configuration(values: ["flight.test": "1"]),
            modules: [FakeServerModule.self]  // LoggingModule arrives transitively
        )
        #expect(app.moduleOrder == ["LoggingModule", "FakeServerModule"])
        #expect(app.container.isFrozen)
        #expect(app.services.count == 1)

        // Cross-module component wiring worked: FakeServer got LoggingModule's sink.
        let server = try app.container.resolve(FakeServer.self)
        let sink = try app.container.resolve(TestLogSink.self)
        #expect(server.sink === sink)
    }

    @Test("Configuration is a resolvable component before any module configures")
    func configurationFirst() throws {
        let app = try Flight.assemble(
            configuration: Configuration(values: ["server.port": "8080"]),
            modules: [LoggingModule.self]
        )
        let config = try app.container.resolve(Configuration.self)
        #expect(config.rawValue(for: "server.port") == "8080")
        #expect(try config.get("server.port", as: Int.self) == 8080)
    }

    @Test("configure-only modules report .running after assembly")
    func healthRunning() throws {
        let app = try Flight.assemble(
            configuration: Configuration(), modules: [FakeServerModule.self])
        let statuses = app.container.moduleStatuses()
        #expect(statuses.count == 2)
        for status in statuses {
            guard case .running = status.health else {
                Issue.record("\(status.moduleName) expected .running, got \(status.health)")
                continue
            }
        }
    }

    @Test("a module throwing in configure fails bootstrap and names itself")
    func configureFailure() {
        do {
            _ = try Flight.assemble(
                configuration: Configuration(), modules: [BrokenConfigureModule.self])
            Issue.record("expected moduleConfigurationFailed")
        } catch let error as BootstrapError {
            guard case .moduleConfigurationFailed(let module, _) = error else {
                Issue.record("expected moduleConfigurationFailed, got \(error)")
                return
            }
            #expect(module == "BrokenConfigureModule")
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test("a failing Service flips its module to .failed")
    func serviceFailureHealth() async throws {
        let app = try Flight.assemble(
            configuration: Configuration(), modules: [FailingServiceModule.self])
        let entry = try #require(app.services.first)

        await #expect(throws: TestServiceError.self) {
            try await entry.service.run()
        }

        let status = try #require(
            app.container.moduleStatuses().first { $0.moduleName == "FailingServiceModule" }
        )
        guard case .failed = status.health else {
            Issue.record("expected .failed, got \(status.health)")
            return
        }
    }

    @Test("eager singleton construction failure surfaces as singletonConstructionFailed")
    func freezeFailure() {
        struct ExplodingModule: FlightModule {
            init() {}
            func configure(_ container: Container) throws {
                container.register(Alpha.self, scope: .singleton) { _ in
                    throw TestServiceError.boom
                }
            }
        }
        do {
            _ = try Flight.assemble(configuration: Configuration(), modules: [ExplodingModule.self])
            Issue.record("expected singletonConstructionFailed")
        } catch let error as BootstrapError {
            guard case .singletonConstructionFailed = error else {
                Issue.record("expected singletonConstructionFailed, got \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test("bootstrap returns immediately when no module owns a service")
    func serviceLessBootstrap() async throws {
        // Valid shape for one-shot CLI-style Flight apps.
        try await Flight.bootstrap(configuration: Configuration(), modules: [LoggingModule.self])
    }

    @Test("a .endsApp service finishing shuts the app down gracefully")
    func oneShotServiceBootstrap() async throws {
        // Default (.failsApp) would make bootstrap throw serviceFinishedUnexpectedly here.
        try await Flight.bootstrap(configuration: Configuration(), modules: [OneShotModule.self])
    }
}
