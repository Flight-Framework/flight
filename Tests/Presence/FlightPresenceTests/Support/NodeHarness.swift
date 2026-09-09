import FlightChannels
import FlightChannelsTesting
import FlightCore
import FlightPubSub
import FlightPubSubTesting
import FlightWeb
import FlightWebTesting
import Foundation
import ServiceLifecycle
import Synchronization
@testable import FlightPresence

/// A complete Flight app node for integration tests: container, channels,
/// presence module, an in-memory socket endpoint — and, when clustered,
/// the PubSub relay and the presence service running as tasks, the way a
/// real deployment's ServiceGroup would run them.
final class PresenceNode: Sendable {
    let client: TestClient
    let tracker: PresenceTracker
    let presence: any Presence
    private let localPubSub: LocalPubSub
    private let serviceTask: Task<Void, Never>
    private let relayTask: Task<Void, Never>?
    private let adapter: InMemoryClusterAdapter?

    /// Fast liveness settings so failure-mode tests run in milliseconds.
    static let fastConfig: [String: String] = [
        "flight.presence.heartbeat-interval-seconds": "0.1",
        "flight.presence.down-after-seconds": "0.5",
        "flight.presence.permdown-after-seconds": "2.0",
        "flight.presence.sweep-interval-seconds": "0.05",
    ]

    init(
        name: String,
        cluster: InMemoryCluster? = nil,
        monitor: (any PresenceMembershipMonitor)? = nil,
        configValues: [String: String] = PresenceNode.fastConfig
    ) throws {
        var mutableValues = configValues
        mutableValues["flight.presence.node-name"] = name
        let nodeConfiguration = Configuration(values: mutableValues)

        // One node, wired explicitly — which is now the only way it can be
        // written. The adapter and the membership monitor are *arguments*
        // rather than components Presence probes the container for: whether
        // this node is clustered, and whether the cluster can say who is up,
        // are facts about how the node was composed.
        let adapter = cluster?.makeAdapter()
        let pubsub = try FlightPubSubModule(
            configuration: nodeConfiguration, adapter: adapter)
        // Presence before Channels: the channel is declared *with* presence,
        // which is the ordering a composition root derives from the same
        // value flow — a channel closes over what it needs rather than
        // looking it up when a join creates it.
        let presenceModule = try FlightPresenceModule(
            configuration: nodeConfiguration,
            localBus: pubsub.local,
            gossipBus: pubsub.bus,
            adapter: adapter,
            membershipMonitor: monitor)
        // Capture the presence value (Sendable), not the module, in the
        // channel factory closure.
        let presence = presenceModule.presence
        let channels = try FlightChannelsModule(
            bus: pubsub.bus,
            configuration: nodeConfiguration,
            channels: [
                ChannelRegistration("room:*") { _ in
                    PresenceRoomChannel(presence: presence)
                }
            ])

        // Upgrade-time authentication (Channels): `?user=` names the
        // principal; absent means an anonymous (watch-only) socket. A route
        // value now, built from the channels module.
        let socket = channels.socketRoute("/socket") { context in
            context.request.queryParam("user").map { BasicPrincipal(subject: $0) }
        }
        self.client = try TestClient(routes: [socket])
        self.tracker = presenceModule.tracker
        self.presence = presence
        self.localPubSub = pubsub.local
        self.adapter = adapter

        // The long-running halves, exactly what bootstrap's ServiceGroup
        // would host: the presence service (from the module), plus the
        // PubSub relay a real adapter module would contribute.
        if let clustered = pubsub.bus as? ClusteredPubSub {
            relayTask = Task { await clustered.runIncomingRelay() }
        } else {
            relayTask = nil
        }
        guard let presenceService = presenceModule.service as? PresenceService else {
            preconditionFailure("FlightPresenceModule should contribute exactly one PresenceService")
        }
        serviceTask = Task { try? await presenceService.run() }
    }

    /// The local (intra-node) bus — where clients' diff frames fan out.
    var localBus: LocalPubSub { localPubSub }

    func wire(user: String?) async throws -> ChannelWireClient {
        let path = user.map { "/socket?user=\($0)" } ?? "/socket"
        return ChannelWireClient(socket: try await client.webSocket(path))
    }

    /// Simulates the process dying: services stop, the node falls silent
    /// on the cluster wire. (Its in-memory sockets die with the test.)
    func crash() {
        serviceTask.cancel()
        relayTask?.cancel()
        adapter?.disconnect()
    }

    func shutdown() async {
        crash()
        await serviceTask.value
        if let relayTask { await relayTask.value }
    }
}

/// The application channel the design's examples assume: track on join,
/// push the initial state, expose a status update event.
struct PresenceRoomChannel: Channel {
    let presence: any Presence

    func join(_ topic: String, socket: Socket) async -> JoinResult {
        if let user = socket.principal?.subject {
            await presence.track(topic: topic, key: user, payload: ["status": "online"], socket: socket)
        }
        await presence.sendState(topic: topic, to: socket)
        return .ok
    }

    func handle(_ event: InboundEvent, socket: Socket) async -> HandleResult {
        switch event.event {
        case "status":
            guard let user = socket.principal?.subject, let status = event.payload["status"]?.stringValue else {
                return .error(reason: "bad_status")
            }
            await presence.update(topic: event.topic, key: user, payload: ["status": status], socket: socket)
            return .reply(.object([:]))
        case "untrack_me":
            guard let user = socket.principal?.subject else { return .error(reason: "anonymous") }
            await presence.untrack(topic: event.topic, key: user, socket: socket)
            return .reply(.object([:]))
        default:
            return .none
        }
    }
}

/// A hand-cranked membership monitor for membership-mode tests.
final class FakeMembershipMonitor: PresenceMembershipMonitor, Sendable {
    private let stream: AsyncStream<PresenceMembershipEvent>
    private let continuation: AsyncStream<PresenceMembershipEvent>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream(of: PresenceMembershipEvent.self)
    }

    func events() -> AsyncStream<PresenceMembershipEvent> { stream }

    func emit(_ event: PresenceMembershipEvent) {
        continuation.yield(event)
    }
}

// MARK: - Wire-level helpers

extension ChannelWireClient {
    /// Joins `topic` and returns every envelope up to and including the
    /// join reply — asserting the reply arrived.
    @discardableResult
    func join(_ topic: String, ref: String = "j1") async throws -> Envelope {
        try send(ref: ref, topic: topic, event: "flight:join")
        while let envelope = try await nextEnvelope() {
            if envelope.event == ReservedEvent.reply.rawValue, envelope.ref == ref {
                return envelope
            }
        }
        throw PollTimeout(what: "join reply for \(topic)")
    }

    /// The next envelope carrying `event`, skipping others.
    func next(event: String) async throws -> Envelope {
        while let envelope = try await nextEnvelope() {
            if envelope.event == event { return envelope }
        }
        throw PollTimeout(what: "envelope with event \(event)")
    }
}
