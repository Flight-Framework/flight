import FlightCore
import struct Foundation.Data
import Testing
@testable import FlightPresence

@Suite("Gossip wire format", .timeLimit(.minutes(1)))
struct GossipTests {

    private let replica = PresenceReplicaID(name: "a", boot: "boot-a")

    @Test("frames round-trip: delta, snapshot, syncRequest")
    func roundTrip() throws {
        var state = PresenceCRDTState()
        let delta = state.add(
            PresenceRecord(topic: "room:1", key: "u", ref: "r", payload: ["s": "x"]),
            at: PresenceDot(replica: replica, counter: 1)
        )
        let messages: [PresenceGossipMessage] = [
            .delta(from: replica, state: delta),
            .snapshot(from: replica, state: state.snapshot(of: replica, clock: 1)),
            .syncRequest(from: replica),
        ]
        for message in messages {
            let data = try #require(PresenceGossipFrame.encode(message))
            let (decoded, unknown) = PresenceGossipFrame.decode(data)
            #expect(decoded == message)
            #expect(unknown == nil)
        }
    }

    @Test("unknown wire versions are identified and dropped, not misread")
    func unknownVersion() {
        let data = Data(#"{"v": 99, "message": {"whatever": true}}"#.utf8)
        let (decoded, unknown) = PresenceGossipFrame.decode(data)
        #expect(decoded == nil)
        #expect(unknown == 99)
    }

    @Test("garbage payloads are dropped without a version misreport")
    func garbage() {
        let (decoded, unknown) = PresenceGossipFrame.decode(Data("not json".utf8))
        #expect(decoded == nil)
        #expect(unknown == nil)
    }
}

@Suite("PresenceConfiguration", .timeLimit(.minutes(1)))
struct PresenceConfigurationTests {

    @Test("defaults: generated node name, 5s heartbeat, 15s down, 300s permdown")
    func defaults() throws {
        let configuration = try PresenceConfiguration(configuration: Configuration())
        #expect(configuration.nodeName.hasPrefix("node-"))
        #expect(configuration.heartbeatInterval == .seconds(5))
        #expect(configuration.downAfter == .seconds(15))
        #expect(configuration.permdownAfter == .seconds(300))
        #expect(configuration.sweepInterval == .seconds(15) / 4)
    }

    @Test("all keys read from the flight.presence namespace")
    func explicitKeys() throws {
        let configuration = try PresenceConfiguration(
            configuration: Configuration(values: [
                "flight.presence.node-name": "web-1",
                "flight.presence.heartbeat-interval-seconds": "2",
                "flight.presence.down-after-seconds": "7",
                "flight.presence.permdown-after-seconds": "60",
                "flight.presence.sweep-interval-seconds": "0.5",
            ])
        )
        #expect(configuration.nodeName == "web-1")
        #expect(configuration.heartbeatInterval == .seconds(2))
        #expect(configuration.downAfter == .seconds(7))
        #expect(configuration.permdownAfter == .seconds(60))
        #expect(configuration.sweepInterval == .milliseconds(500))
    }

    @Test("down-after must exceed the heartbeat interval — a heartbeat gap must not flap a node (§5.2)")
    func downAfterValidation() {
        #expect(throws: PresenceConfigurationError.downAfterNotAboveHeartbeat(heartbeat: 10, downAfter: 5)) {
            _ = try PresenceConfiguration(
                configuration: Configuration(values: [
                    "flight.presence.heartbeat-interval-seconds": "10",
                    "flight.presence.down-after-seconds": "5",
                ])
            )
        }
    }

    @Test("non-positive intervals are refused")
    func positivityValidation() {
        #expect(throws: PresenceConfigurationError.nonPositiveInterval) {
            _ = try PresenceConfiguration(
                configuration: Configuration(values: [
                    "flight.presence.heartbeat-interval-seconds": "0"
                ])
            )
        }
    }
}
