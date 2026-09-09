import Foundation
import Logging
import ServiceLifecycle
import Synchronization
import Testing
import FlightCore
import FlightPubSub
import FlightPubSubTesting

/// What an adapter-providing module looks like now: provide an adapter. That
/// is the whole contract.
///
/// It used to be three obligations — register the adapter component, declare
/// `FlightPubSubModule` as a dependency, and remember to expose
/// `PubSubRelayService` as the module's service — and forgetting the third
/// gave a cluster that relayed nothing, silently. `FlightPubSubModule` takes
/// the adapter and owns the relay, so an adapter module is now a *dependency*
/// of PubSub rather than a dependent.
///
/// Note what is gone from this fixture: the `@TaskLocal` that existed only to
/// smuggle a value past `init()`, the held `Container`, and `configure`
/// itself. The module simply holds the adapter it provides.
private struct InMemoryAdapterModule: FlightModule {
    let adapter: any DistributedPubSubAdapter

    init(cluster: InMemoryCluster) {
        self.adapter = cluster.makeAdapter()
    }
}

// Static cluster slot ⇒ these tests must not interleave.
@Suite("Module wiring", .serialized, .timeLimit(.minutes(1)))
struct ModuleTests {

    @Test("local-only app: the bus is the local core, and no service is registered")
    func localOnly() async throws {
        let configuration = Configuration()
        let module = try FlightPubSubModule(configuration: configuration)
        let app = try Flight.assemble(configuration: configuration, modules: [module])

        // The bus is what consumers use; with no adapter it is the local core.
        #expect(module.bus is LocalPubSub)
        #expect(app.services.isEmpty)

        // `any PubSub` (the bus) and the concrete `local` core are one instance.
        #expect((module.bus as? LocalPubSub) === module.local)

        // And it works, end to end.
        var iterator = module.bus.subscribe("app:events").makeAsyncIterator()
        await module.bus.publish(msg("app:events", "wired"))
        let received = await iterator.next()
        #expect(received.map(text) == "wired")
    }

    @Test("adapter module present: the bus is clustered, relay service collected")
    func withAdapter() async throws {
        // The adapter is built first and handed to PubSub — the direction the
        // old design had reversed.
        let configuration = Configuration()
        let adapterModule = InMemoryAdapterModule(cluster: InMemoryCluster())
        let pubsub = try FlightPubSubModule(
            configuration: configuration, adapter: adapterModule.adapter)
        let app = try Flight.assemble(
            configuration: configuration, modules: [adapterModule, pubsub])

        #expect(pubsub.bus is ClusteredPubSub)
        // The relay is PubSub's now: it is what holds both halves.
        #expect(app.services.count == 1)
        #expect(app.services[0].moduleName == "FlightPubSubModule")
        #expect(app.moduleOrder == ["InMemoryAdapterModule", "FlightPubSubModule"])

        // The clustered bus wraps the same local core — a subscriber on the
        // concrete local component sees messages published via the bus.
        var iterator = pubsub.local.subscribe("t").makeAsyncIterator()
        await pubsub.bus.publish(msg("t", "same-core"))
        let received = await iterator.next()
        #expect(received.map(text) == "same-core")
    }

    @Test("two bootstrapped apps form a cluster; graceful shutdown ends both cleanly")
    func endToEndTwoApps() async throws {
        // One cluster, two apps, each with its own adapter drawn from it.
        let cluster = InMemoryCluster()
        let configuration = Configuration()
        func app() throws -> (app: AssembledApplication, bus: any PubSub) {
            let adapterModule = InMemoryAdapterModule(cluster: cluster)
            let pubsub = try FlightPubSubModule(
                configuration: configuration, adapter: adapterModule.adapter)
            let assembled = try Flight.assemble(
                configuration: configuration, modules: [adapterModule, pubsub])
            return (assembled, pubsub.bus)
        }
        let appA = try app()
        let appB = try app()

        func serviceGroup(for app: AssembledApplication, label: String) -> ServiceGroup {
            ServiceGroup(configuration: .init(
                services: app.services.map { .init(service: $0.service) },
                logger: Logger(label: label)
            ))
        }
        let groupA = serviceGroup(for: appA.app, label: "test.app-a")
        let groupB = serviceGroup(for: appB.app, label: "test.app-b")
        let runningA = Task { try await groupA.run() }
        let runningB = Task { try await groupB.run() }

        var onB = appB.bus.subscribe("cluster:t").makeAsyncIterator()
        await appA.bus.publish(msg("cluster:t", "across-apps"))
        let received = await onB.next()
        #expect(received.map(text) == "across-apps")

        await groupA.triggerGracefulShutdown()
        await groupB.triggerGracefulShutdown()
        try await runningA.value
        try await runningB.value
    }

    @Test("FlightPubSubModule declares no dependencies, and has no service without an adapter")
    func moduleShape() throws {
        #expect(FlightPubSubModule.dependencies.isEmpty)
        #expect(try FlightPubSubModule(configuration: Configuration()).service == nil)
    }
}

/// The configuration cross-check on the single-node fallback.
///
/// Composing by argument is right, but it means an unloaded adapter module
/// looks exactly like a deliberate single-node deployment. These pin the one
/// signal that tells them apart: configuration nobody would have written
/// unless they wanted the adapter.
@Suite("Unloaded adapter modules", .serialized, .timeLimit(.minutes(1)))
struct UnloadedAdapterTests {

    @Test("pubsub.valkey.url with no adapter fails module construction instead of going single-node")
    func configuredButNotLoaded() throws {
        let configuration = Configuration(values: ["pubsub.valkey.url": "valkey://127.0.0.1:6379"])

        // The cross-check runs when the module is built with no adapter — it
        // refuses to become a silent single node.
        let error = #expect(throws: (any Error).self) {
            _ = try FlightPubSubModule(configuration: configuration)
        }
        let message = String(describing: try #require(error))
        #expect(message.contains("pubsub.valkey.url"))
        // Names the module that actually provides it. The message used to say
        // no adapter module shipped and to write your own, which stopped
        // being true when flight-data grew FlightPubSubValkeyModule — so the
        // error sent an operator to build something they already had.
        #expect(message.contains("FlightPubSubValkeyModule"))
    }

    @Test("the generic adapter key is watched too")
    func genericAdapterKeyIsWatched() throws {
        let configuration = Configuration(values: ["pubsub.adapter.url": "nats://127.0.0.1:4222"])
        let error = #expect(throws: (any Error).self) {
            _ = try FlightPubSubModule(configuration: configuration)
        }
        #expect(String(describing: try #require(error)).contains("pubsub.adapter.url"))
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

    @Test("an adapter present reads its own configuration — no cross-check fires")
    func configuredAndLoaded() async throws {
        // Same configuration as the failing case. The adapter here is not the
        // Valkey one, but that is what the check is about: an adapter *was*
        // supplied, so the fallback branch — and its cross-check — never runs.
        let configuration = Configuration(values: ["pubsub.valkey.url": "valkey://127.0.0.1:6379"])
        let adapterModule = InMemoryAdapterModule(cluster: InMemoryCluster())
        let pubsub = try FlightPubSubModule(
            configuration: configuration, adapter: adapterModule.adapter)
        _ = try Flight.assemble(
            configuration: configuration, modules: [adapterModule, pubsub])

        #expect(pubsub.bus is ClusteredPubSub)
    }

    @Test("no adapter and no configuration is the ordinary single-node app")
    func neitherConfiguredNorLoaded() throws {
        let configuration = Configuration()
        let module = try FlightPubSubModule(configuration: configuration)
        #expect(module.bus is LocalPubSub)
    }
}
