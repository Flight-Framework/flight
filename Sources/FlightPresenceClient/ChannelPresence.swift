import FlightChannelsClient
import FlightPresenceProtocol
import struct Foundation.UUID

/// The Swift client presence helper (design §6, Channels §7.2): consumes a
/// channel's message stream, applies `flight:presence_state` /
/// `flight:presence_diff` payloads through the shared `PresenceSync` rules,
/// and hands application code a maintained list — never raw diff plumbing.
///
///     let room = client.channel("room:42")
///     let presence = ChannelPresence(channel: room)
///     await presence.start()
///     try await room.join()
///     for await change in await presence.changes() {
///         render(change.list)   // full list, every time it changes
///     }
///
/// Reconnection is covered by the server, not the helper: after a rejoin
/// the application calls `sendState` again server-side (or used it in
/// `join`, the normal shape), so a fresh `flight:presence_state` arrives
/// and resets the map — `PresenceSync.applyState` reports exactly who came
/// and went while the client was away.
public actor ChannelPresence {

    /// One observed change: the maintained list after applying a message,
    /// plus the net joins/leaves that message caused (meta updates appear
    /// in `joins` only — normalized, §6).
    public struct Change: Sendable, Equatable {
        public let list: [PresenceEntry]
        public let joins: [String: [PresenceMeta]]
        public let leaves: [String: [PresenceMeta]]
    }

    private let channel: ChannelHandle
    private var sync = PresenceSync()
    private var pump: Task<Void, Never>?
    private var observers: [UUID: AsyncStream<Change>.Continuation] = [:]

    public init(channel: ChannelHandle) {
        self.channel = channel
    }

    deinit {
        pump?.cancel()
        for observer in observers.values { observer.finish() }
    }

    /// Begins consuming the channel's messages. Call before `join()` so
    /// the initial state message cannot be missed. Idempotent.
    public func start() async {
        guard pump == nil else { return }
        let stream = await channel.messages()
        pump = Task { [weak self] in
            for await message in stream {
                guard let self else { return }
                await self.handle(message)
            }
        }
    }

    /// Stops consuming and finishes every observer stream.
    public func stop() {
        pump?.cancel()
        pump = nil
        for observer in observers.values { observer.finish() }
        observers.removeAll()
    }

    /// The current presence list, sorted by key.
    public var list: [PresenceEntry] { sync.list }

    /// Every change from now on. Multiple streams may be open; each sees
    /// every change from its creation until `stop()`.
    public func changes() -> AsyncStream<Change> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: Change.self)
        observers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { [weak self] in await self?.removeObserver(id) }
        }
        return stream
    }

    private func removeObserver(_ id: UUID) {
        observers.removeValue(forKey: id)
    }

    private func handle(_ message: ChannelMessage) {
        let change: PresenceSyncChange
        switch message.event {
        case PresenceEvent.state:
            change = sync.applyState(message.payload)
        case PresenceEvent.diff:
            change = sync.applyDiff(message.payload)
        default:
            return
        }
        guard !change.isEmpty else { return }
        let update = Change(list: sync.list, joins: change.joins, leaves: change.leaves)
        for observer in observers.values {
            observer.yield(update)
        }
    }
}
