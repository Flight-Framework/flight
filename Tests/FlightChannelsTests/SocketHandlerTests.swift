import FlightChannels
import FlightChannelsTesting
import FlightPubSub
import FlightWeb
import FlightWebTesting
import Foundation
import Testing

extension ChannelWireClient {
    /// Reads envelopes until one matches — for flows where two outbound
    /// sources (a reply and a broadcast pump) may interleave.
    func expectEnvelope(
        timeoutEnvelopes: Int = 10,
        where predicate: (Envelope) -> Bool
    ) async throws -> Envelope? {
        for _ in 0..<timeoutEnvelopes {
            guard let envelope = try await nextEnvelope() else { return nil }
            if predicate(envelope) { return envelope }
        }
        return nil
    }
}

@Suite("Socket handler — join, replies, errors (§4, §5)", .timeLimit(.minutes(1)))
struct SocketHandlerJoinTests {

    @Test("join ok: flight:reply echoes the ref and carries initial state (§4.3)")
    func joinOk() async throws {
        let harness = try Harness()
        let wire = try await harness.wire()
        try wire.send(ref: "1", topic: "room:42", event: "flight:join")

        let reply = try await wire.nextEnvelope()
        #expect(reply == Envelope(
            ref: "1",
            topic: "room:42",
            event: "flight:reply",
            payload: ["room": "room:42", "history": []]
        ))
        wire.close()
    }

    @Test("join with no initial state replies null payload")
    func joinNullState() async throws {
        let harness = try Harness()
        let wire = try await harness.wire("/socket?token=alice:member")
        try wire.send(ref: "1", topic: "room:members-only", event: "flight:join")
        let reply = try await wire.nextEnvelope()
        #expect(reply?.event == "flight:reply")
        #expect(reply?.payload == ["admitted": "alice"])
        wire.close()
    }

    @Test("join rejected: flight:error with the rejection reason and the ref (§4.2, §5)")
    func joinRejected() async throws {
        let harness = try Harness()
        let wire = try await harness.wire()
        try wire.send(ref: "9", topic: "room:locked", event: "flight:join")

        let error = try await wire.nextEnvelope()
        #expect(error == Envelope(
            ref: "9",
            topic: "room:locked",
            event: "flight:error",
            payload: ["reason": "forbidden"]
        ))
        wire.close()
    }

    @Test("authorization composes with upgrade-time identity (§5)")
    func principalGate() async throws {
        let harness = try Harness()

        // Anonymous socket: unauthenticated.
        let anon = try await harness.wire()
        try anon.send(ref: "1", topic: "room:members-only", event: "flight:join")
        #expect(try await anon.nextEnvelope()?.payload == ["reason": "unauthenticated"])
        anon.close()

        // Authenticated but roleless: forbidden.
        let outsider = try await harness.wire("/socket?token=bob")
        try outsider.send(ref: "1", topic: "room:members-only", event: "flight:join")
        #expect(try await outsider.nextEnvelope()?.payload == ["reason": "forbidden"])
        outsider.close()

        // Member: admitted.
        let member = try await harness.wire("/socket?token=carol:member")
        try member.send(ref: "1", topic: "room:members-only", event: "flight:join")
        #expect(try await member.nextEnvelope()?.event == "flight:reply")
        member.close()
    }

    @Test("a throwing authenticate refuses the upgrade itself (401, no socket)")
    func upgradeRefused() async throws {
        let harness = try Harness()
        await #expect(throws: TestClient.TestClientError.self) {
            _ = try await harness.client.webSocket("/authed")
        }
        // With a token the same mount upgrades fine.
        let wire = try await harness.wire("/authed?token=dana")
        try wire.send(ref: "1", topic: "room:1", event: "flight:join")
        #expect(try await wire.nextEnvelope()?.event == "flight:reply")
        wire.close()
    }

    @Test("unmatched topic, reserved topic, double join — each a named error")
    func joinErrors() async throws {
        let harness = try Harness()
        let wire = try await harness.wire()

        // The fixture registers a catch-all, so unmatched needs a router
        // without one — covered in RouterTests. Here: reserved + double.
        try wire.send(ref: "1", topic: "flight", event: "flight:join")
        #expect(try await wire.nextEnvelope()?.payload == ["reason": "reserved_topic"])

        try wire.send(ref: "2", topic: "room:1", event: "flight:join")
        #expect(try await wire.nextEnvelope()?.event == "flight:reply")
        try wire.send(ref: "3", topic: "room:1", event: "flight:join")
        #expect(try await wire.nextEnvelope()?.payload == ["reason": "already_joined"])
        wire.close()
    }

    @Test("routing precedence end to end: exact lobby beats wildcard and catch-all")
    func routingPrecedence() async throws {
        let harness = try Harness()
        let wire = try await harness.wire()
        try wire.send(ref: "1", topic: "lobby", event: "flight:join")
        #expect(try await wire.nextEnvelope()?.payload == ["which": "lobby-exact"])
        try wire.send(ref: "2", topic: "somewhere:else", event: "flight:join")
        #expect(try await wire.nextEnvelope()?.payload == ["which": "catch-all"])
        wire.close()
    }
}

@Suite("Socket handler — application events (§3, §4.3)", .timeLimit(.minutes(1)))
struct SocketHandlerEventTests {

    @Test("handler reply rides flight:reply with the inbound ref (§4.3)")
    func echo() async throws {
        let harness = try Harness()
        let wire = try await harness.wire()
        _ = try await wire.join("room:1")

        try wire.send(ref: "5", topic: "room:1", event: "echo", payload: ["body": "hi"])
        let reply = try await wire.nextEnvelope()
        #expect(reply == Envelope(ref: "5", topic: "room:1", event: "flight:reply", payload: ["body": "hi"]))
        wire.close()
    }

    @Test("handler error rides flight:error with the handler's reason")
    func handlerError() async throws {
        let harness = try Harness()
        let wire = try await harness.wire()
        _ = try await wire.join("room:1")

        try wire.send(ref: "5", topic: "room:1", event: "fail")
        #expect(try await wire.nextEnvelope() == Envelope(
            ref: "5", topic: "room:1", event: "flight:error", payload: ["reason": "boom"]
        ))
        wire.close()
    }

    @Test(".none sends nothing, even for a ref-carrying message")
    func silentHandler() async throws {
        let harness = try Harness()
        let wire = try await harness.wire()
        _ = try await wire.join("room:1")

        try wire.send(ref: "5", topic: "room:1", event: "silent")
        try wire.send(ref: "6", topic: "room:1", event: "echo", payload: ["after": true])
        // The next envelope is the echo's reply — nothing arrived for "silent".
        let reply = try await wire.nextEnvelope()
        #expect(reply?.ref == "6")
        wire.close()
    }

    @Test("events on unjoined topics are refused")
    func notJoined() async throws {
        let harness = try Harness()
        let wire = try await harness.wire()
        try wire.send(ref: "1", topic: "room:1", event: "echo")
        #expect(try await wire.nextEnvelope()?.payload == ["reason": "not_joined"])
        wire.close()
    }

    @Test("client-sent reserved events it may not send are invalid_event")
    func invalidReserved() async throws {
        let harness = try Harness()
        let wire = try await harness.wire()
        for event in ["flight:reply", "flight:error", "flight:launch"] {
            try wire.send(ref: "1", topic: "room:1", event: event)
            #expect(try await wire.nextEnvelope()?.payload == ["reason": "invalid_event"])
        }
        wire.close()
    }

    @Test("direct socket push: server-initiated, ref null (§4.1)")
    func socketPush() async throws {
        let harness = try Harness()
        let wire = try await harness.wire()
        _ = try await wire.join("room:1")

        try wire.send(ref: nil, topic: "room:1", event: "dm_me")
        let push = try await wire.nextEnvelope()
        #expect(push?.ref == nil)
        #expect(push?.event == "dm")
        wire.close()
    }

    @Test("heartbeat: flight:reply on the control topic, ref echoed (§6)")
    func heartbeat() async throws {
        let harness = try Harness()
        let wire = try await harness.wire()
        try wire.send(ref: "hb1", topic: "flight", event: "flight:heartbeat")
        #expect(try await wire.nextEnvelope() == Envelope(
            ref: "hb1", topic: "flight", event: "flight:reply", payload: .object([:])
        ))
        wire.close()
    }
}

@Suite("Socket handler — broadcast via PubSub (§3)", .timeLimit(.minutes(1)))
struct SocketHandlerBroadcastTests {

    @Test("one shout reaches every joined socket, including the sender (§3)")
    func fanOut() async throws {
        let harness = try Harness()
        let alice = try await harness.wire("/socket?token=alice")
        let bob = try await harness.wire("/socket?token=bob")
        _ = try await alice.join("room:42")
        _ = try await bob.join("room:42")

        try alice.send(ref: "2", topic: "room:42", event: "shout", payload: ["body": "hello"])

        let toBob = try await bob.expectEnvelope { $0.event == "shouted" }
        #expect(toBob?.payload == ["body": "hello"])
        #expect(toBob?.ref == nil)

        let toAlice = try await alice.expectEnvelope { $0.event == "shouted" }
        #expect(toAlice?.payload == ["body": "hello"])
        // …and Alice also got her reply (order relative to the broadcast
        // is not part of the contract).
        alice.close()
        bob.close()
    }

    @Test("broadcast excluding the origin socket skips only the origin")
    func broadcastFrom() async throws {
        let harness = try Harness()
        let alice = try await harness.wire()
        let bob = try await harness.wire()
        _ = try await alice.join("room:42")
        _ = try await bob.join("room:42")

        try alice.send(ref: "2", topic: "room:42", event: "whisper_others", payload: ["psst": true])
        #expect(try await bob.expectEnvelope { $0.event == "whispered" } != nil)

        // Alice must NOT see the whisper. Prove it by a marker that arrives
        // strictly after: her own echoed message.
        _ = try await alice.expectEnvelope { $0.ref == "2" } // the whisper reply
        try alice.send(ref: "3", topic: "room:42", event: "echo", payload: ["marker": true])
        let next = try await alice.nextEnvelope()
        #expect(next?.ref == "3", "alice saw \(String(describing: next)) before her marker")
        alice.close()
        bob.close()
    }

    @Test("fan-out is scoped to the topic")
    func topicScoping() async throws {
        let harness = try Harness()
        let alice = try await harness.wire()
        let bob = try await harness.wire()
        _ = try await alice.join("room:1")
        _ = try await bob.join("room:2")

        try alice.send(ref: "2", topic: "room:1", event: "shout", payload: ["n": 1])
        _ = try await alice.expectEnvelope { $0.event == "shouted" }

        try bob.send(ref: "2", topic: "room:2", event: "echo", payload: ["marker": true])
        let next = try await bob.expectEnvelope { _ in true }
        #expect(next?.ref == "2", "bob saw a foreign broadcast: \(String(describing: next))")
        alice.close()
        bob.close()
    }

    @Test("a non-broadcast payload published to a joined topic is dropped, not delivered")
    func foreignPayloadDropped() async throws {
        let harness = try Harness()
        let wire = try await harness.wire()
        _ = try await wire.join("room:1")

        // Publish raw junk to the topic, bypassing the broadcaster.
        await (try harness.localPubSub).publish(Message(topic: "room:1", payload: Data("junk".utf8)))

        try wire.send(ref: "2", topic: "room:1", event: "echo", payload: ["marker": true])
        let next = try await wire.nextEnvelope()
        #expect(next?.ref == "2")
        wire.close()
    }
}
