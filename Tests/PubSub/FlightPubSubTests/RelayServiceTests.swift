import Foundation
import Testing
import FlightCore
import FlightPubSub
import FlightPubSubTesting

@Suite("PubSubRelayService", .timeLimit(.minutes(1)))
struct RelayServiceTests {

    @Test("wiring error: a container whose PubSub is local-only")
    func notClusteredThrows() async throws {
        let container = Container()
        container.register((any PubSub).self, scope: .singleton) { _ in LocalPubSub() }
        try container.freeze()

        let service = PubSubRelayService(container: container)
        await #expect(throws: PubSubWiringError.self) {
            try await service.run()
        }
    }

    @Test("container-wired relay drains the adapter into local fan-out")
    func containerWiredRelay() async throws {
        let adapter = RecordingAdapter()
        let container = Container()
        container.register((any PubSub).self, scope: .singleton) { _ in
            ClusteredPubSub(local: LocalPubSub(), adapter: adapter, nodeID: "svc-node")
        }
        try container.freeze()
        let clustered = try container.resolve((any PubSub).self)

        var iterator = clustered.subscribe("room:1").makeAsyncIterator()
        let running = Task { try await PubSubRelayService(container: container).run() }

        adapter.inject(msg("room:1", "via-service", metadata: [ClusteredPubSub.originMetadataKey: "peer"]))
        let received = await iterator.next()
        #expect(received.map(text) == "via-service")

        // Stream end = relay done; run() returns without error.
        adapter.finishIncoming()
        try await running.value
    }

    @Test("directly-embedded relay stops promptly on cancellation")
    func cancellation() async throws {
        let adapter = RecordingAdapter()
        let clustered = ClusteredPubSub(local: LocalPubSub(), adapter: adapter, nodeID: "n")
        let running = Task { try await PubSubRelayService(clustered: clustered).run() }
        running.cancel()
        try await running.value  // returning without error is the assertion
    }
}
