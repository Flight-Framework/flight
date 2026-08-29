import FlightChannelsProtocol
import FlightPubSub
import Logging
import struct Foundation.UUID
import struct Foundation.Data
import class Foundation.JSONDecoder
import class Foundation.JSONEncoder

/// What one channel broadcast looks like inside a PubSub `Message` payload:
/// the envelope minus what PubSub already carries (`topic` is the message's
/// own topic) and what fan-out never has (`ref` — server pushes are
/// uncorrelated).
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
        guard let frame = try? WireCoders.decoder.decode(BroadcastFrame.self, from: message.payload) else {
            return nil
        }
        self = frame
    }
}

/// The one way Channels hands fan-out to PubSub: encode `(event,
/// payload)` into a `Message` and publish. Channels never implements
/// fan-out itself — whether the other subscriber is on this node or another
/// machine is PubSub's seam (step 3→4), invisible here.
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

    /// Metadata key carrying the fully-encoded wire frame for this
    /// broadcast — internal, deliberately not `public`.
    ///
    /// Every joined socket's final `Envelope` for a given broadcast is
    /// byte-identical (same topic, same event, same payload, `ref: nil`).
    /// `SocketSession.pump` used to rebuild and re-encode that Envelope once
    /// per *subscriber*; at 200 subscribers that is 200 redundant decodes of
    /// the same bytes plus 200 redundant re-encodes of the same result. This
    /// key lets `publish` do that work exactly once, here, and hand every
    /// pump the same `String` by reference.
    ///
    /// Purely additive: `data` below is still the real `BroadcastFrame`
    /// payload, unchanged, so a publisher that isn't `ChannelBroadcaster`
    /// (Presence hand-builds one directly) produces a `Message` with no such
    /// key, and `pump` falls back to decoding it exactly as before. Nothing
    /// depends on this key being present.
    internal static let precomputedFrameMetadataKey = "flight.channels.frame"

    /// Names the broadcaster instance that stamped a precomputed frame.
    ///
    /// Without it the key above is an unvalidated injection seam: any
    /// in-process publisher that stamped `flight.channels.frame` on a
    /// `Message` got that string forwarded verbatim to every joined socket,
    /// *bypassing the reserved-event guard and valid-envelope framing* — so
    /// app code that misused a reserved key could push a `flight:join` to
    /// every subscriber. The token is per-instance and never leaves the
    /// process, so only frames this broadcaster actually built are trusted;
    /// anything else falls back to the decode path, which validates.
    ///
    /// The same shape `ClusteredPubSub` uses for echo suppression, and for
    /// the same reason: an operator-supplied or guessable name is not a
    /// capability.
    internal static let frameTokenMetadataKey = "flight.channels.frame-token"

    /// The value under ``frameTokenMetadataKey``.
    ///
    /// Process-wide rather than per-instance: the seam being closed is app
    /// code stamping a reserved key, and every broadcaster in this process is
    /// equally the framework. A per-instance token would additionally have to
    /// be threaded down to every `SocketSession`, for no threat it stops.
    /// Never serialized to another node — a clustered frame arrives without
    /// it and takes the validating decode path, which is correct.
    internal static let frameToken = UUID().uuidString

    private let pubsub: any PubSub
    private let logger: Logger

    public init(pubsub: any PubSub, logger: Logger = Logger(label: "flight.channels.broadcast")) {
        self.pubsub = pubsub
        self.logger = logger
    }

    /// Fan `event` out to every subscriber of `topic` — all joined sockets
    /// on every node (PubSub), including the sender's, if joined.
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
        // Dropped and logged rather than asserted: a `precondition` here took
        // the whole process down — every connected socket on this node —
        // because one broadcast used a reserved name. See `Socket.push` for
        // how a client-derived name reaches this.
        guard !event.hasPrefix(ReservedEvent.prefix) else {
            logger.error(
                "refusing to broadcast an event in the reserved flight: namespace",
                metadata: ["topic": "\(topic)", "event": "\(event)"]
            )
            return
        }
        let frame = BroadcastFrame(event: event, payload: payload)
        // A two-field Codable struct of JSON-representable values cannot
        // fail to encode.
        guard let data = try? WireCoders.encoder.encode(frame) else { return }

        // Precompute the one wire frame every local (and, once serialized
        // for a clustered adapter, every remote) subscriber will send
        // byte-for-byte identical — `ref` is always nil on a broadcast, and
        // `topic` is this call's topic for every subscriber of it. One
        // encode here replaces N decodes + N re-encodes at delivery.
        var metadata = metadata
        if let text = try? Envelope(ref: nil, topic: topic, event: event, payload: payload).encodedText() {
            metadata[Self.precomputedFrameMetadataKey] = text
            metadata[Self.frameTokenMetadataKey] = Self.frameToken
        }
        await pubsub.publish(Message(topic: topic, payload: data, metadata: metadata))
    }
}
