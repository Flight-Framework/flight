import FlightChannelsProtocol
import FlightPubSub
import struct Foundation.Data
import class Foundation.JSONDecoder
import class Foundation.JSONEncoder

/// What one channel broadcast looks like inside a PubSub `Message` payload:
/// the envelope minus what PubSub already carries (`topic` is the message's
/// own topic) and what fan-out never has (`ref` — server pushes are
/// uncorrelated, §4.3).
///
/// Public because it *is* the seam contract: anything that publishes to a
/// topic in this shape reaches every joined client — a channel handler via
/// `ChannelBroadcaster`, a background job, or (later) Flight Presence and
/// Flight Live.
public struct BroadcastFrame: Sendable, Equatable, Codable {
    public let event: String
    public let payload: JSONValue

    public init(event: String, payload: JSONValue) {
        self.event = event
        self.payload = payload
    }

    /// Decodes a PubSub message's payload; nil if the payload is not a
    /// broadcast frame (foreign publisher on a shared topic — dropped, with
    /// a log line, by the subscription pump).
    public init?(message: Message) {
        guard let frame = try? JSONDecoder().decode(BroadcastFrame.self, from: message.payload) else {
            return nil
        }
        self = frame
    }
}

/// The one way Channels hands fan-out to PubSub (§3): encode `(event,
/// payload)` into a `Message` and publish. Channels never implements
/// fan-out itself — whether the other subscriber is on this node or another
/// machine is PubSub's seam (§3, step 3→4), invisible here.
///
/// Registered as a singleton by `FlightChannelsModule`; resolve it from any
/// channel factory or service:
///
///     container.registerChannel("room:*") { c in
///         RoomChannel(broadcaster: try c.resolve(ChannelBroadcaster.self))
///     }
public struct ChannelBroadcaster: Sendable {
    /// Metadata key carrying the originating socket's `id` for
    /// `broadcast(..., excluding:)`. Namespaced like PubSub's own reserved
    /// keys; application metadata must not use it.
    public static let originMetadataKey = "flight.channels.origin"

    private let pubsub: any PubSub

    public init(pubsub: any PubSub) {
        self.pubsub = pubsub
    }

    /// Fan `event` out to every subscriber of `topic` — all joined sockets
    /// on every node (PubSub §5), including the sender's, if joined.
    public func broadcast(topic: String, event: String, payload: JSONValue = .object([:])) async {
        await publish(topic: topic, event: event, payload: payload, metadata: [:])
    }

    /// Fan out to every subscriber *except* `socket` — the "tell everyone
    /// else" shape a chat message wants when the sender already rendered
    /// its own message optimistically.
    public func broadcast(
        topic: String,
        event: String,
        payload: JSONValue = .object([:]),
        excluding socket: Socket
    ) async {
        await publish(
            topic: topic,
            event: event,
            payload: payload,
            metadata: [Self.originMetadataKey: socket.id]
        )
    }

    private func publish(topic: String, event: String, payload: JSONValue, metadata: [String: String]) async {
        precondition(
            !event.hasPrefix(ReservedEvent.prefix),
            "'\(event)' is in the reserved flight: namespace (§4.2); application broadcasts must use their own event names."
        )
        let frame = BroadcastFrame(event: event, payload: payload)
        // A two-field Codable struct of JSON-representable values cannot
        // fail to encode.
        guard let data = try? JSONEncoder().encode(frame) else { return }
        await pubsub.publish(Message(topic: topic, payload: data, metadata: metadata))
    }
}
