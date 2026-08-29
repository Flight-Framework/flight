import FlightPresenceProtocol
import FlightPubSub
import Foundation
import Testing

@testable import FlightPresence

/// What a gossip frame is allowed to say.
///
/// The trust boundary is the PubSub bus — anything that can publish to
/// `flight:presence` is inside it, and none of this changes that
/// (`Docs/presence.md`, "What this trusts"). These rules bound what a *buggy*
/// peer, or one running a version that means something else by the same
/// bytes, can do to a healthy node's state. Every one of them is a thing no
/// correct sender ever does, which is what makes them safe on by default.
@Suite("Gossip frame validation", .timeLimit(.minutes(1)))
struct GossipTrustTests {

    private let peer = PresenceReplicaID(name: "peer", boot: "boot-peer")
    private let stranger = PresenceReplicaID(name: "stranger", boot: "boot-stranger")

    private func record(_ key: String, topic: String = "room:1") -> PresenceRecord {
        PresenceRecord(topic: topic, key: key, ref: "r-\(key)", payload: ["status": "online"])
    }

    private func frame(_ message: PresenceGossipMessage) -> Message {
        Message(
            topic: PresenceGossip.topic,
            payload: PresenceGossipFrame.encode(message) ?? Data())
    }

    @Test("a frame asserting a third replica's entries is dropped whole")
    func foreignEntriesAreRefused() async throws {
        // No correct sender does this: `snapshot(of:)` carries own entries and
        // deltas carry own dots. Merging it let one confused node speak for
        // the whole cluster — assert presences for replicas it has never
        // heard from, and have them believed.
        let (tracker, _) = makeTracker(name: "local")

        var state = PresenceCRDTState()
        _ = state.add(record("impostor"), at: PresenceDot(replica: stranger, counter: 1))
        await tracker.receiveGossip(frame(.snapshot(from: peer, state: state)))

        #expect(await tracker.list(topic: "room:1").isEmpty, "a forged entry was merged")
    }

    @Test("a frame speaking only for its sender is merged as usual")
    func ownEntriesAreAccepted() async throws {
        let (tracker, _) = makeTracker(name: "local")

        var state = PresenceCRDTState()
        _ = state.add(record("alice"), at: PresenceDot(replica: peer, counter: 1))
        await tracker.receiveGossip(frame(.snapshot(from: peer, state: state)))

        #expect(await tracker.list(topic: "room:1").map(\.key) == ["alice"])
    }

    @Test("a frame over the per-frame entry cap is dropped")
    func oversizedFrameIsRefused() async throws {
        let configuration = PresenceConfiguration(nodeName: "local", maxEntriesPerFrame: 2)
        let (tracker, _) = makeTracker(name: "local", configuration: configuration)

        var state = PresenceCRDTState()
        for index in 1...3 {
            _ = state.add(record("user:\(index)"), at: PresenceDot(replica: peer, counter: UInt64(index)))
        }
        await tracker.receiveGossip(frame(.snapshot(from: peer, state: state)))

        #expect(await tracker.list(topic: "room:1").isEmpty, "an oversized frame was merged")
    }

    @Test("a frame at the cap is still accepted — the bound is not off by one")
    func frameAtTheCapIsAccepted() async throws {
        let configuration = PresenceConfiguration(nodeName: "local", maxEntriesPerFrame: 2)
        let (tracker, _) = makeTracker(name: "local", configuration: configuration)

        var state = PresenceCRDTState()
        for index in 1...2 {
            _ = state.add(record("user:\(index)"), at: PresenceDot(replica: peer, counter: UInt64(index)))
        }
        await tracker.receiveGossip(frame(.snapshot(from: peer, state: state)))

        #expect(await tracker.list(topic: "room:1").count == 2)
    }

    @Test("the cap can be turned off")
    func capIsOptional() async throws {
        let configuration = PresenceConfiguration(nodeName: "local", maxEntriesPerFrame: nil)
        let (tracker, _) = makeTracker(name: "local", configuration: configuration)

        var state = PresenceCRDTState()
        for index in 1...50 {
            _ = state.add(record("user:\(index)"), at: PresenceDot(replica: peer, counter: UInt64(index)))
        }
        await tracker.receiveGossip(frame(.snapshot(from: peer, state: state)))

        #expect(await tracker.list(topic: "room:1").count == 50)
    }

    @Test("an unrecognised wire version is dropped, not guessed at")
    func unknownVersionIsDropped() async throws {
        // The rolling-upgrade story: two halves of a cluster across a version
        // change do not merge each other's state. A visible partition beats
        // two versions agreeing on the bytes and disagreeing on the meaning.
        let (tracker, _) = makeTracker(name: "local")
        let payload = Data(#"{"v":999,"message":{"syncRequest":{"from":{"name":"p","boot":"b"}}}}"#.utf8)
        await tracker.receiveGossip(Message(topic: PresenceGossip.topic, payload: payload))
        #expect(await tracker.knownPeers().isEmpty, "an unknown-version frame was acted on")
    }
}
