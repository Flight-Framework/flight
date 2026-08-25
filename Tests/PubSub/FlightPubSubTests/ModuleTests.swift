import Foundation
import Logging
import ServiceLifecycle
import Synchronization
import Testing
import FlightCore
import FlightPubSub
import FlightPubSubTesting

/// What an adapter-providing module looks like (README "Writing an adapter
/// module"): register the adapter component, depend on `FlightPubSubModule`,
/// expose the relay as the module's service. The static slot exists only
/// because `FlightModule` conformances are instantiated by `assemble` with
/// no arguments — tests park the cluster there first.
private final class InMemoryAdapterModule: FlightModule {
    static let clusterSlot = Mutex<InMemoryCluster?>(nil)
    static var dependencies: [any FlightModule.Type] { [FlightPubSubModule.self] }

    struct ClusterSlotUnset: Error {}

    private var container: Container?

    init() {}

    func configure(_ container: Container) throws {
        self.container = container
        container.register((any DistributedPubSubAdapter).self, scope: .singleton) { _ in
            guard let cluster = InMemoryAdapterModule.clusterSlot.withLock({ $0 }) else {
                throw ClusterSlotUnset()
            }
            return cluster.makeAdapter()
        }
    }

    var service: (any Service)? {
        container.map { PubSubRelayService(container: $0) }
    }
}

// Static cluster slot ⇒ these tests must not interleave.
@Suite("Module wiring", .serialized, .timeLimit(.minutes(1)))
struct ModuleTests {

    @Test("local-only app: PubSub component is the local core, and no service is registered")
    func localOnly() async throws {
        let app = try Flight.assemble(configuration: Configuration(), modules: [FlightPubSubModule.self])

        let pubsub = try app.container.resolve((any PubSub).self)
        #expect(pubsub is LocalPubSub)
        #expect(app.services.isEmpty)

        // `any PubSub` and the concrete `LocalPubSub` component are one instance.
        let local = try app.container.resolve(LocalPubSub.self)
        #expect((pubsub as? LocalPubSub) === local)

        // And it works, end to end, straight out of the container.
        var iterator = pubsub.subscribe("app:events").makeAsyncIterator()
        await pubsub.publish(msg("app:events", "wired"))
        let received = await iterator.next()
        #expect(received.map(text) == "wired")
    }

    @Test("adapter module present: PubSub component is clustered, relay service collected")
    func withAdapter() async throws {
        InMemoryAdapterModule.clusterSlot.withLock { $0 = InMemoryCluster() }
        defer { InMemoryAdapterModule.clusterSlot.withLock { $0 = nil } }

        // FlightPubSubModule arrives transitively via the adapter module's DAG.
        let app = try Flight.assemble(configuration: Configuration(), modules: [InMemoryAdapterModule.self])

        let pubsub = try app.container.resolve((any PubSub).self)
        #expect(pubsub is ClusteredPubSub)
        #expect(app.services.count == 1)
        #expect(app.services[0].moduleName == "InMemoryAdapterModule")
        #expect(app.moduleOrder == ["FlightPubSubModule", "InMemoryAdapterModule"])

        // The clustered component wraps the registered LocalPubSub — a subscriber
        // on the concrete local component sees messages published via `any PubSub`.
        let local = try app.container.resolve(LocalPubSub.self)
        var iterator = local.subscribe("t").makeAsyncIterator()
        await pubsub.publish(msg("t", "same-core"))
        let received = await iterator.next()
        #expect(received.map(text) == "same-core")
    }

    @Test("two bootstrapped apps form a cluster; graceful shutdown ends both cleanly")
    func endToEndTwoApps() async throws {
        InMemoryAdapterModule.clusterSlot.withLock { $0 = InMemoryCluster() }
        defer { InMemoryAdapterModule.clusterSlot.withLock { $0 = nil } }

        let appA = try Flight.assemble(configuration: Configuration(), modules: [InMemoryAdapterModule.self])
        let appB = try Flight.assemble(configuration: Configuration(), modules: [InMemoryAdapterModule.self])

        func serviceGroup(for app: AssembledApplication, label: String) -> ServiceGroup {
            ServiceGroup(configuration: .init(
                services: app.services.map { .init(service: $0.service) },
                logger: Logger(label: label)
            ))
        }
        let groupA = serviceGroup(for: appA, label: "test.app-a")
        let groupB = serviceGroup(for: appB, label: "test.app-b")
        let runningA = Task { try await groupA.run() }
        let runningB = Task { try await groupB.run() }

        let pubsubA = try appA.container.resolve((any PubSub).self)
        let pubsubB = try appB.container.resolve((any PubSub).self)

        var onB = pubsubB.subscribe("cluster:t").makeAsyncIterator()
        await pubsubA.publish(msg("cluster:t", "across-apps"))
        let received = await onB.next()
        #expect(received.map(text) == "across-apps")

        await groupA.triggerGracefulShutdown()
        await groupB.triggerGracefulShutdown()
        try await runningA.value
        try await runningB.value
    }

    @Test("FlightPubSubModule declares no dependencies and defaults to no service")
    func moduleShape() {
        #expect(FlightPubSubModule.dependencies.isEmpty)
        #expect(FlightPubSubModule().service == nil)
    }
}

/// The configuration cross-check on the single-node fallback.
///
/// Composing by presence is right, but it means an unloaded adapter module
/// looks exactly like a deliberate single-node deployment. These pin the one
/// signal that tells them apart: configuration nobody would have written
/// unless they wanted the adapter.
@Suite("Unloaded adapter modules", .serialized, .timeLimit(.minutes(1)))
struct UnloadedAdapterTests {

    @Test("pubsub.valkey.url with no adapter module fails assembly instead of going single-node")
    func configuredButNotLoaded() throws {
        let configuration = Configuration(values: ["pubsub.valkey.url": "valkey://127.0.0.1:6379"])

        // The factory runs at freeze(), so what surfaces is a BootstrapError
        // carrying the message — assembly refuses, which is the contract.
        let error = #expect(throws: (any Error).self) {
            try Flight.assemble(configuration: configuration, modules: [FlightPubSubModule.self])
        }
        let message = String(describing: try #require(error))
        #expect(message.contains("pubsub.valkey.url"))
        #expect(message.contains("FlightPubSubValkeyModule"))
    }

    @Test("the message names the module to add and the key to remove")
    func messageIsActionable() {
        let error = UnloadedAdapterError(
            feature: "PubSub",
            configurationKey: "pubsub.valkey.url",
            module: "FlightPubSubValkeyModule")

        // Whoever hits this at 3am gets both ways out of it, by name.
        #expect(error.description.contains("FlightPubSubValkeyModule"))
        #expect(error.description.contains("pubsub.valkey.url"))
        #expect(error.description.contains("Flight.bootstrap(modules:)"))
    }

    @Test("an adapter module present reads its own configuration — no cross-check fires")
    func configuredAndLoaded() throws {
        InMemoryAdapterModule.clusterSlot.withLock { $0 = InMemoryCluster() }
        defer { InMemoryAdapterModule.clusterSlot.withLock { $0 = nil } }

        // Same configuration as the failing case. The adapter here is not the
        // Valkey one, but presence is what the check is about: something
        // registered an adapter, so the fallback branch never runs.
        let configuration = Configuration(values: ["pubsub.valkey.url": "valkey://127.0.0.1:6379"])
        let app = try Flight.assemble(configuration: configuration, modules: [InMemoryAdapterModule.self])

        #expect(try app.container.resolve((any PubSub).self) is ClusteredPubSub)
    }

    @Test("no adapter and no configuration is the ordinary single-node app")
    func neitherConfiguredNorLoaded() throws {
        let app = try Flight.assemble(configuration: Configuration(), modules: [FlightPubSubModule.self])
        #expect(try app.container.resolve((any PubSub).self) is LocalPubSub)
    }
}
