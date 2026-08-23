import FlightChannels
import FlightPresenceProtocol
import FlightPubSub
import Foundation
import Synchronization
import Testing
@testable import FlightPresence

// MARK: - Deterministic randomness

/// SplitMix64 — a tiny, deterministic RNG so every property-test failure
/// reports a reproducible seed.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { self.state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// MARK: - Async polling

struct PollTimeout: Error, CustomStringConvertible {
    let what: String
    var description: String { "condition not met within timeout: \(what)" }
}

/// Polls until `condition` is true; throws after `timeout`. The standard
/// idiom for asserting on state that settles through actor hops and PubSub
/// deliveries.
func eventually(
    _ what: String = "condition",
    timeout: Duration = .seconds(5),
    interval: Duration = .milliseconds(10),
    condition: () async throws -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if try await condition() { return }
        try await Task.sleep(for: interval)
    }
    guard try await condition() else { throw PollTimeout(what: what) }
}

// MARK: - Diff capture

/// Subscribes to one channel topic on a PubSub and collects the presence
/// broadcast frames Presence publishes there — what a joined socket's pump
/// would forward to its client.
final class DiffCollector: Sendable {
    private final class Storage: Sendable {
        let frames = Mutex<[BroadcastFrame]>([])
    }

    private let storage = Storage()
    private let pump: Mutex<Task<Void, Never>?> = Mutex(nil)

    init(pubsub: some PubSub, topic: String) {
        let stream = pubsub.subscribe(topic)
        let storage = self.storage
        let task = Task {
            for await message in stream {
                guard let frame = try? JSONDecoder().decode(BroadcastFrame.self, from: message.payload) else {
                    continue
                }
                storage.frames.withLock { $0.append(frame) }
            }
        }
        pump.withLock { $0 = task }
    }

    deinit {
        pump.withLock { $0?.cancel() }
    }

    var all: [BroadcastFrame] { storage.frames.withLock { $0 } }
    var diffs: [JSONValue] { all.filter { $0.event == PresenceEvent.diff }.map(\.payload) }
    var count: Int { storage.frames.withLock { $0.count } }

    /// The collected diffs replayed through the shared client state
    /// machine — the view a client that joined before all of them would
    /// hold.
    func replayedView() -> PresenceSync {
        var sync = PresenceSync()
        for payload in diffs {
            sync.applyDiff(payload)
        }
        return sync
    }
}

// MARK: - Fake socket (the PresenceSocket seam)

/// A controllable stand-in for `Socket`: tests drive topic activation,
/// termination, and close, and read back reserved pushes — local presence
/// semantics without a WebSocket stack.
final class FakeSocket: PresenceSocket, Sendable {
    struct Push: Equatable, Sendable {
        let topic: String
        let event: String
        let payload: JSONValue
    }

    private struct State {
        var closed = false
        var active: Set<String> = []
        var onActivated: [String: [@Sendable () -> Void]] = [:]
        var onTerminated: [String: [@Sendable () -> Void]] = [:]
        var pushes: [Push] = []
    }

    let id: String
    private let state = Mutex(State())

    init(id: String = UUID().uuidString) {
        self.id = id
    }

    var pushes: [Push] { state.withLock { $0.pushes } }

    // Mirrors Socket's SPI semantics exactly (Channels seam).

    func onTopicActivated(_ topic: String, perform: @escaping @Sendable () -> Void) {
        let fireNow: Bool? = state.withLock { state in
            if state.closed { return nil }
            if state.active.contains(topic) { return true }
            state.onActivated[topic, default: []].append(perform)
            return false
        }
        if fireNow == true { perform() }
    }

    func onTopicTerminated(_ topic: String, perform: @escaping @Sendable () -> Void) {
        let fireNow = state.withLock { state in
            if state.closed { return true }
            state.onTerminated[topic, default: []].append(perform)
            return false
        }
        if fireNow { perform() }
    }

    func pushReserved(topic: String, event: String, payload: JSONValue) {
        state.withLock { $0.pushes.append(Push(topic: topic, event: event, payload: payload)) }
    }

    // Test controls

    func activate(_ topic: String) {
        let observers = state.withLock { state -> [@Sendable () -> Void] in
            state.active.insert(topic)
            return state.onActivated.removeValue(forKey: topic) ?? []
        }
        for observer in observers { observer() }
    }

    func terminate(_ topic: String) {
        let observers = state.withLock { state -> [@Sendable () -> Void] in
            state.active.remove(topic)
            state.onActivated.removeValue(forKey: topic)
            return state.onTerminated.removeValue(forKey: topic) ?? []
        }
        for observer in observers { observer() }
    }

    func close() {
        let observers = state.withLock { state -> [@Sendable () -> Void] in
            state.closed = true
            state.active.removeAll()
            state.onActivated.removeAll()
            let pending = state.onTerminated.values.flatMap { $0 }
            state.onTerminated.removeAll()
            return pending
        }
        for observer in observers { observer() }
    }
}

// MARK: - Common fixtures

func makeTracker(
    name: String = "test-node",
    mode: PresenceMode = .singleNode,
    localBus: LocalPubSub? = nil,
    gossipBus: (any PubSub)? = nil,
    configuration: PresenceConfiguration = PresenceConfiguration(nodeName: "test-node")
) -> (tracker: PresenceTracker, localBus: LocalPubSub) {
    let local = localBus ?? LocalPubSub()
    let tracker = PresenceTracker(
        replica: PresenceReplicaID(name: name, boot: "boot-\(name)-\(UUID().uuidString.prefix(6))"),
        mode: mode,
        configuration: configuration,
        localBus: local,
        gossipBus: gossipBus ?? local
    )
    return (tracker, local)
}

func metas(in state: JSONValue, key: String) -> [PresenceMeta] {
    PresenceWire.entries(from: state)[key] ?? []
}
