import FlightActuator
import FlightCore
import FlightWeb
import FlightWebTesting
import Testing

/// §3/§6: the snapshot is a plain assembly of what Core already tracks —
/// no HTTP round-trip required to test it.
@Suite("ActuatorSnapshot assembly")
struct SnapshotTests {

    @Test("snapshot carries every registered bean with its metadata")
    func snapshotCarriesBeans() throws {
        let container = try TestContainer.build { SampleAppModule() }
        let snapshot = ActuatorSnapshot(container: container, environment: .test)

        #expect(snapshot.environment == .test)

        let service = try #require(snapshot.beans.first {
            $0.typeName == "FlightActuatorTests.SampleService"
        })
        #expect(service.scope == .singleton)
        #expect(service.stereotype == .service)

        let repository = try #require(snapshot.beans.first {
            $0.typeName == "FlightActuatorTests.SampleRepository"
        })
        #expect(repository.stereotype == .repository)

        let transient = try #require(snapshot.beans.first {
            $0.typeName == "FlightActuatorTests.SampleTransient"
        })
        #expect(transient.scope == .transient)

        // Qualified duplicate-type registrations stay distinguishable —
        // the reason ComponentDescriptor carries the qualifier at all.
        let qualified = snapshot.beans.filter {
            $0.typeName == "FlightActuatorTests.SampleQualified"
        }
        #expect(qualified.map(\.qualifier) == ["primary", "secondary"])
    }

    @Test("snapshot reflects a module whose service failed at run time")
    func snapshotReflectsModuleFailure() async throws {
        // The real health path: assemble tracks health externally, and the
        // health-wrapped service records the failure on the live container.
        let app = try assemble(
            configuration: Configuration(),
            modules: [FailingServiceModule.self]
        )
        let failing = try #require(app.services.first)
        await #expect(throws: FailingServiceModule.Boom.self) {
            try await failing.service.run()
        }

        let snapshot = ActuatorSnapshot(
            environment: .test,
            modules: app.container.moduleStatuses(),
            beans: app.container.allRegistrations()
        )
        let status = try #require(snapshot.modules.first {
            $0.moduleName == "FailingServiceModule"
        })
        #expect(status.health.isFailed)
        #expect(snapshot.modules.contains { $0.health.isFailed })
        #expect(status.health.failureDescription?.contains("flux capacitor") == true)
    }

    @Test("configured modules report running health")
    func configuredModulesRunning() throws {
        let app = try assemble(
            configuration: Configuration(),
            modules: [FailingServiceModule.self]
        )
        // Configure succeeded and the service has not run yet: .running
        // (Flight Core §6.1 — registration-only view of a configured module).
        let snapshot = ActuatorSnapshot(container: app.container, environment: .test)
        #expect(snapshot.modules.count == 1)
        #expect(snapshot.modules[0].health.isRunning)
    }
}

@Suite("ModuleHealth presentation helpers")
struct ModuleHealthHelperTests {
    struct SomeError: Error, CustomStringConvertible {
        var description: String { "it broke" }
    }

    @Test("predicates match exactly one state each")
    func predicates() {
        #expect(ModuleHealth.failed(SomeError()).isFailed)
        #expect(!ModuleHealth.running.isFailed)
        #expect(!ModuleHealth.notStarted.isFailed)

        #expect(ModuleHealth.running.isRunning)
        #expect(!ModuleHealth.failed(SomeError()).isRunning)

        #expect(ModuleHealth.notStarted.isNotStarted)
        #expect(!ModuleHealth.running.isNotStarted)
    }

    @Test("labels are the stable wire vocabulary")
    func labels() {
        #expect(ModuleHealth.notStarted.actuatorLabel == "notStarted")
        #expect(ModuleHealth.running.actuatorLabel == "running")
        #expect(ModuleHealth.failed(SomeError()).actuatorLabel == "failed")

        #expect(Lifetime.singleton.actuatorLabel == "singleton")
        #expect(Lifetime.transient.actuatorLabel == "transient")
        #expect(Lifetime.scoped.actuatorLabel == "scoped")

        #expect(Stereotype.component.actuatorLabel == "component")
        #expect(Stereotype.service.actuatorLabel == "service")
        #expect(Stereotype.repository.actuatorLabel == "repository")
        #expect(Stereotype.controller.actuatorLabel == "controller")
    }

    @Test("failureDescription surfaces the error only for .failed")
    func failureDescription() {
        #expect(ModuleHealth.failed(SomeError()).failureDescription == "it broke")
        #expect(ModuleHealth.running.failureDescription == nil)
        #expect(ModuleHealth.notStarted.failureDescription == nil)
    }
}
