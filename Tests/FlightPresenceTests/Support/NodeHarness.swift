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
    let container: Container
    let client: TestClient
    let tracker: PresenceTracker
    let presence: any Presence
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
        struct NodeModule: FlightModule {
            static var dependencies: [any FlightModule.Type] { [FlightPresenceModule.self] }
            func configure(_ container: Container) throws {}
        }

        let container = Container()
        var mutableValues = configValues
        mutableValues["flight.presence.node-name"] = name
        let values = mutableValues
        container.register(Configuration.self, scope: .singleton) { _ in Configuration(values: values) }

        let adapter = cluster?.makeAdapter()
        if let adapter {
            container.register((any DistributedPubSubAdapter).self, scope: .singleton) { _ in adapter }
        }
        if let monitor {
            container.register((any PresenceMembershipMonitor).self, scope: .singleton) { _ in monitor }
        }

        var services: [any Service] = []
        for moduleType in try resolveModuleOrder([NodeModule.self]) {
            let module = moduleType.init()
            try module.configure(container)
            if let service = module.service { services.append(service) }
        }

        container.registerChannel("room:*") { container in
            PresenceRoomChannel(presence: try container.resolve((any Presence).self))
        }
        // Upgrade-time authentication (Channels §5): `?user=` names the
        // principal; absent means an anonymous (watch-only) socket.
        container.registerChannelSocket("/socket") { context in
            context.request.queryParam("user").map { BasicPrincipal(subject: $0) }
        }
        try container.freeze()

        self.container = container
        self.client = try TestClient(container: container)
        self.tracker = try container.resolve(PresenceTracker.self)
        self.presence = try container.resolve((any Presence).self)
        self.adapter = adapter

        // The long-running halves, exactly what bootstrap's ServiceGroup
        // would host: the presence service (from the module), plus the
        // PubSub relay a real adapter module would contribute.
        if let clustered = try container.resolve((any PubSub).self) as? ClusteredPubSub {
            relayTask = Task { await clustered.runIncomingRelay() }
        } else {
            relayTask = nil
        }
        let presenceServices = services.compactMap { $0 as? PresenceService }
        precondition(presenceServices.count == 1, "FlightPresenceModule should contribute exactly one service")
        let presenceService = presenceServices[0]
        serviceTask = Task { try? await presenceService.run() }
    }

    /// The local (intra-node) bus — where clients' diff frames fan out.
    var localBus: LocalPubSub {
        get throws { try container.resolve(LocalPubSub.self) }
    }

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
