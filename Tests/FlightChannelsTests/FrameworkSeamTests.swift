@_spi(FlightInternal) import FlightChannels
import FlightChannelsTesting
import FlightCore
import FlightPubSub
import FlightWeb
import FlightWebTesting
import Foundation
import Synchronization
import Testing

/// The `@_spi(FlightInternal)` seams sibling framework packages (Presence,
/// later Live) build on: reserved-event pushes to one socket, and
/// observation of a socket's topic-membership lifecycle. Exercised through
/// the full in-process stack — the observers fire from the real
/// SocketSession paths (join, leave, teardown), not from a mock.
@Suite("Framework seams (SPI)", .timeLimit(.minutes(1)))
struct FrameworkSeamTests {

    /// Records lifecycle callbacks and captures the socket at join time.
    final class SeamProbe: Sendable {
        private let state = Mutex<(events: [String], socket: Socket?)>(([], nil))

        func record(_ event: String) { state.withLock { $0.events.append(event) } }
        func capture(_ socket: Socket) { state.withLock { $0.socket = socket } }

        var events: [String] { state.withLock { $0.events } }
        var socket: Socket? { state.withLock { $0.socket } }

        func waitFor(_ predicate: @escaping ([String]) -> Bool) async -> Bool {
            for _ in 0..<200 {
                if predicate(events) { return true }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return predicate(events)
        }
    }

    /// Registers seam observers the way Presence does: from within `join`.
    struct SeamChannel: Channel {
        let probe: SeamProbe

        func join(_ topic: String, socket: Socket) async -> JoinResult {
            probe.capture(socket)
            socket.onTopicActivated(topic) { [probe] in probe.record("activated \(topic)") }
            socket.onTopicTerminated(topic) { [probe] in probe.record("terminated \(topic)") }
            return .ok
        }

        func handle(_ event: InboundEvent, socket: Socket) async -> HandleResult {
            if event.event == "push_reserved" {
                socket.pushReserved(topic: event.topic, event: "flight:presence_state", payload: ["who": "me"])
                return .none
            }
            return .none
        }
    }

    private func harness() throws -> (client: TestClient, probe: SeamProbe) {
        let probe = SeamProbe()
        let container = Container()
        container.register(Configuration.self, scope: .singleton) { _ in Configuration() }
        struct SeamModule: FlightModule {
            static var dependencies: [any FlightModule.Type] { [FlightChannelsModule.self] }
            func configure(_ container: Container) throws {}
        }
        for moduleType in try resolveModuleOrder([SeamModule.self]) {
            try moduleType.init().configure(container)
        }
        container.registerChannel("seam:*") { _ in SeamChannel(probe: probe) }
        container.registerChannelSocket("/socket")
        try container.freeze()
        return (try TestClient(container: container), probe)
    }

    @Test("onTopicActivated fires after the join is fully established")
    func activationFiresOnJoin() async throws {
        let (client, probe) = try harness()
        let wire = ChannelWireClient(socket: try await client.webSocket("/socket"))

        try wire.send(ref: "1", topic: "seam:a", event: "flight:join")
        _ = try await wire.nextEnvelope()  // join reply
        #expect(await probe.waitFor { $0 == ["activated seam:a"] })
    }

    @Test("client leave fires termination for that topic only")
    func terminationOnLeave() async throws {
        let (client, probe) = try harness()
        let wire = ChannelWireClient(socket: try await client.webSocket("/socket"))

        try wire.send(ref: "1", topic: "seam:a", event: "flight:join")
        try wire.send(ref: "2", topic: "seam:b", event: "flight:join")
        try wire.send(ref: "3", topic: "seam:a", event: "flight:leave")
        _ = try await wire.nextEnvelope()
        _ = try await wire.nextEnvelope()
        _ = try await wire.nextEnvelope()

        #expect(await probe.waitFor { $0.contains("terminated seam:a") })
        #expect(!probe.events.contains("terminated seam:b"))
    }

    @Test("socket close fires termination for every membership")
    func terminationOnClose() async throws {
        let (client, probe) = try harness()
        let wire = ChannelWireClient(socket: try await client.webSocket("/socket"))

        try wire.send(ref: "1", topic: "seam:a", event: "flight:join")
        try wire.send(ref: "2", topic: "seam:b", event: "flight:join")
        _ = try await wire.nextEnvelope()
        _ = try await wire.nextEnvelope()
        #expect(await probe.waitFor { $0.filter { $0.hasPrefix("activated") }.count == 2 })

        wire.close()
        #expect(await probe.waitFor { events in
            events.contains("terminated seam:a") && events.contains("terminated seam:b")
        })
    }

    @Test("observers registered on an already-closed socket fire immediately — cleanup can never leak")
    func observersAfterClose() async throws {
        let (client, probe) = try harness()
        let wire = ChannelWireClient(socket: try await client.webSocket("/socket"))

        try wire.send(ref: "1", topic: "seam:a", event: "flight:join")
        _ = try await wire.nextEnvelope()
        wire.close()
        #expect(await probe.waitFor { $0.contains("terminated seam:a") })

        let socket = try #require(probe.socket)
        let late = Mutex(false)
        socket.onTopicTerminated("seam:whatever") { late.withLock { $0 = true } }
        #expect(late.withLock { $0 })

        // Activation observers on a closed socket are dropped, not fired.
        let neverActive = Mutex(false)
        socket.onTopicActivated("seam:whatever") { neverActive.withLock { $0 = true } }
        #expect(!neverActive.withLock { $0 })
    }

    @Test("pushReserved delivers a flight:* event to exactly this socket")
    func pushReserved() async throws {
        let (client, probe) = try harness()
        _ = probe
        let wire = ChannelWireClient(socket: try await client.webSocket("/socket"))
        let bystander = ChannelWireClient(socket: try await client.webSocket("/socket"))

        try wire.send(ref: "1", topic: "seam:a", event: "flight:join")
        try bystander.send(ref: "1", topic: "seam:a", event: "flight:join")
        _ = try await wire.nextEnvelope()
        _ = try await bystander.nextEnvelope()

        try wire.send(ref: nil, topic: "seam:a", event: "push_reserved")
        let received = try await wire.nextEnvelope()
        #expect(received?.event == "flight:presence_state")
        #expect(received?.ref == nil)
        #expect(received?.payload == .object(["who": .string("me")]))

        // The bystander saw nothing: single-socket delivery, not fan-out.
        bystander.close()
        while let envelope = try await bystander.nextEnvelope() {
            #expect(envelope.event != "flight:presence_state")
        }
    }
}
