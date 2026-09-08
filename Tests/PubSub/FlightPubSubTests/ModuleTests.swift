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
/// smuggle a value past `init()`, and the held `Container`. Both were
/// workarounds for a module that could not take what it needed.
private struct InMemoryAdapterModule: FlightModule {
    let adapter: any DistributedPubSubAdapter

    init(cluster: InMemoryCluster) {
        self.adapter = cluster.makeAdapter()
    }

    init() {
        preconditionFailure("InMemoryAdapterModule takes a cluster; construct it directly.")
    }

    func configure(_ container: Container) throws {
        let adapter = self.adapter
        container.register((any DistributedPubSubAdapter).self, scope: .singleton) { _ in adapter }
    }
}

// Static cluster slot ⇒ these tests must not interleave.
@Suite("Module wiring", .serialized, .timeLimit(.minutes(1)))
struct ModuleTests {

    @Test("local-only app: PubSub component is the local core, and no service is registered")
    func localOnly() async throws {
        let configuration = Configuration()
        let app = try Flight.assemble(
            configuration: configuration,
            modules: [try FlightPubSubModule(configuration: configuration)])

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
        do {
            // The adapter is built first and handed to PubSub — the direction
            // the old design had reversed.
            let configuration = Configuration()
            let adapterModule = InMemoryAdapterModule(cluster: InMemoryCluster())
            let app = try Flight.assemble(
                configuration: configuration,
                modules: [
                    adapterModule,
                    try FlightPubSubModule(configuration: configuration, adapter: adapterModule.adapter),
                ])

            let pubsub = try app.container.resolve((any PubSub).self)
            #expect(pubsub is ClusteredPubSub)
            // The relay is PubSub's now: it is what holds both halves.
            #expect(app.services.count == 1)
            #expect(app.services[0].moduleName == "FlightPubSubModule")
            #expect(app.moduleOrder == ["InMemoryAdapterModule", "FlightPubSubModule"])

            // The clustered component wraps the registered LocalPubSub — a subscriber
            // on the concrete local component sees messages published via `any PubSub`.
            let local = try app.container.resolve(LocalPubSub.self)
            var iterator = local.subscribe("t").makeAsyncIterator()
            await pubsub.publish(msg("t", "same-core"))
            let received = await iterator.next()
            #expect(received.map(text) == "same-core")
    
        }
    }

    @Test("two bootstrapped apps form a cluster; graceful shutdown ends both cleanly")
    func endToEndTwoApps() async throws {
        do {
            // One cluster, two apps, each with its own adapter drawn from it.
            let cluster = InMemoryCluster()
            let configuration = Configuration()
            func app() throws -> AssembledApplication {
                let adapterModule = InMemoryAdapterModule(cluster: cluster)
                return try Flight.assemble(
                    configuration: configuration,
                    modules: [
                        adapterModule,
                        try FlightPubSubModule(
                            configuration: configuration, adapter: adapterModule.adapter),
                    ])
            }
            let appA = try app()
            let appB = try app()

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
    }

    @Test("FlightPubSubModule declares no dependencies, and has no service without an adapter")
    func moduleShape() throws {
        #expect(FlightPubSubModule.dependencies.isEmpty)
        #expect(try FlightPubSubModule(configuration: Configuration()).service == nil)
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
            try Flight.assemble(
                configuration: configuration,
                modules: [try FlightPubSubModule(configuration: configuration)])
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
            try Flight.assemble(
                configuration: configuration,
                modules: [try FlightPubSubModule(configuration: configuration)])
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

    @Test("an adapter module present reads its own configuration — no cross-check fires")
    func configuredAndLoaded() async throws {
        // Same configuration as the failing case. The adapter here is not the
        // Valkey one, but that is what the check is about: an adapter *was*
        // supplied, so the fallback branch — and its cross-check — never runs.
        let configuration = Configuration(values: ["pubsub.valkey.url": "valkey://127.0.0.1:6379"])
        let adapterModule = InMemoryAdapterModule(cluster: InMemoryCluster())
        let app = try Flight.assemble(
            configuration: configuration,
            modules: [
                adapterModule,
                try FlightPubSubModule(configuration: configuration, adapter: adapterModule.adapter),
            ])

        #expect(try app.container.resolve((any PubSub).self) is ClusteredPubSub)
    }

    @Test("no adapter and no configuration is the ordinary single-node app")
    func neitherConfiguredNorLoaded() throws {
        let configuration = Configuration()
        let app = try Flight.assemble(
            configuration: configuration,
            modules: [try FlightPubSubModule(configuration: configuration)])
        #expect(try app.container.resolve((any PubSub).self) is LocalPubSub)
    }
}
