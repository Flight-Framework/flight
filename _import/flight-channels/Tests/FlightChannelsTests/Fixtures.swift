import FlightChannels
import FlightChannelsTesting
import FlightCore
import FlightPubSub
import FlightWeb
import FlightWebTesting
import Foundation
import Synchronization

// MARK: - Recording

/// Observes channel lifecycle from the outside — which (topic, subject)
/// pairs have left, which sockets got joined — so tests can assert on
/// teardown behavior without reaching into the handler.
final class ChannelEvents: Sendable {
    private let state = Mutex<[String]>([])

    func record(_ entry: String) {
        state.withLock { $0.append(entry) }
    }

    var entries: [String] {
        state.withLock { $0 }
    }

    /// Polls until `predicate` passes or ~2s elapse — teardown runs
    /// asynchronously relative to the client observing the close.
    func waitFor(_ predicate: @escaping ([String]) -> Bool) async -> Bool {
        for _ in 0..<200 {
            if predicate(entries) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return predicate(entries)
    }
}

// MARK: - Fixture channels

/// The room channel: echoes, broadcasts, errors, direct pushes — one of
/// each server behavior the protocol can express.
struct RoomChannel: Channel {
    let broadcaster: ChannelBroadcaster
    let events: ChannelEvents

    func join(_ topic: String, socket: Socket) async -> JoinResult {
        switch topic {
        case "room:locked":
            return .reject(.forbidden)
        case "room:members-only":
            guard let principal = socket.principal else { return .reject(.unauthenticated) }
            guard principal.hasRole("member") || principal.hasRole("admin") else {
                return .reject(.forbidden)
            }
            return .ok(initialState: ["admitted": .string(principal.subject)])
        default:
            events.record("join \(topic) by \(socket.principal?.subject ?? "anon")")
            return .ok(initialState: ["room": .string(topic), "history": []])
        }
    }

    func handle(_ event: InboundEvent, socket: Socket) async -> HandleResult {
        switch event.event {
        case "echo":
            return .reply(event.payload)
        case "shout":
            await broadcaster.broadcast(topic: event.topic, event: "shouted", payload: event.payload)
            return .reply(["sent": true])
        case "whisper_others":
            await broadcaster.broadcast(
                topic: event.topic,
                event: "whispered",
                payload: event.payload,
                excluding: socket
            )
            return .reply(["sent": true])
        case "dm_me":
            socket.push(topic: event.topic, event: "dm", payload: ["for": .string(socket.id)])
            return .none
        case "fail":
            return .error(reason: "boom")
        case "silent":
            return .none
        default:
            return .error(reason: "unknown_event")
        }
    }

    func leave(_ topic: String, socket: Socket) async {
        events.record("leave \(topic) by \(socket.principal?.subject ?? "anon")")
    }
}

/// Exact-topic channel, to prove exact beats wildcard in routing.
struct LobbyChannel: Channel {
    func join(_ topic: String, socket: Socket) async -> JoinResult {
        .ok(initialState: ["which": "lobby-exact"])
    }

    func handle(_ event: InboundEvent, socket: Socket) async -> HandleResult {
        .reply(["from": "lobby"])
    }
}

/// Catch-all channel, lowest routing precedence.
struct CatchAllChannel: Channel {
    func join(_ topic: String, socket: Socket) async -> JoinResult {
        .ok(initialState: ["which": "catch-all"])
    }

    func handle(_ event: InboundEvent, socket: Socket) async -> HandleResult {
        .none
    }
}

// MARK: - Fixture module

/// The app module every server test boots: channels for `room:*` (wildcard),
/// `lobby` (exact), `*` (catch-all), and two socket mounts — anonymous
/// `/socket` (with optional `?token=` identity) and strict `/authed` (401
/// without a token). Token convention: the token string is the subject;
/// `"…:member"` / `"…:admin"` suffixes grant roles (":" because "+" in a
/// query decodes as a space).
struct ChannelsFixtureModule: FlightModule {
    static var dependencies: [any FlightModule.Type] {
        [FlightChannelsModule.self]
    }

    func configure(_ container: Container) throws {
        container.register(ChannelEvents.self, scope: .singleton) { _ in ChannelEvents() }

        container.registerChannel("room:*", source: "ChannelsFixtureModule") { container in
            RoomChannel(
                broadcaster: try container.resolve(ChannelBroadcaster.self),
                events: try container.resolve(ChannelEvents.self)
            )
        }
        container.registerChannel("lobby", source: "ChannelsFixtureModule") { _ in
            LobbyChannel()
        }
        container.registerChannel("*", source: "ChannelsFixtureModule") { _ in
            CatchAllChannel()
        }

        container.registerChannelSocket("/socket") { context in
            principal(from: context)
        }
        container.registerChannelSocket("/authed") { context in
            guard let principal = principal(from: context) else {
                throw HTTPError(.unauthorized)
            }
            return principal
        }
    }
}

private func principal(from context: RequestContext) -> BasicPrincipal? {
    guard let token = context.request.queryParam("token") else { return nil }
    var parts = token.split(separator: ":").map(String.init)
    let subject = parts.removeFirst()
    return BasicPrincipal(subject: subject, roles: Set(parts))
}

// MARK: - Harness

struct Harness {
    let container: Container
    let client: TestClient

    /// Short heartbeat windows by default so liveness tests run in
    /// milliseconds; generous enough that normal tests never trip them.
    init(
        heartbeatTimeoutSeconds: Double = 5,
        checkIntervalSeconds: Double = 0.05
    ) throws {
        let configuration = Configuration(values: [
            "flight.channels.heartbeat-timeout-seconds": "\(heartbeatTimeoutSeconds)",
            "flight.channels.heartbeat-check-interval-seconds": "\(checkIntervalSeconds)",
        ])
        self.container = try TestContainer.build(configuration: configuration) {
            ChannelsFixtureModule()
        }
        self.client = try TestClient(container: container)
    }

    func wire(_ path: String = "/socket") async throws -> ChannelWireClient {
        ChannelWireClient(socket: try await client.webSocket(path))
    }

    var events: ChannelEvents {
        get throws { try container.resolve(ChannelEvents.self) }
    }

    var localPubSub: LocalPubSub {
        get throws { try container.resolve(LocalPubSub.self) }
    }
}

// MARK: - Envelope test helpers

extension ChannelWireClient {
    /// Joins and asserts the ok-reply arrived, returning its payload.
    @discardableResult
    func join(_ topic: String, ref: String = "j1") async throws -> Envelope? {
        try send(ref: ref, topic: topic, event: "flight:join")
        return try await nextEnvelope()
    }
}
