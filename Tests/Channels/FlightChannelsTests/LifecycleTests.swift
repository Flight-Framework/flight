import FlightChannelsTesting
import FlightWeb
import FlightWebTesting
import Foundation
import Synchronization
import Testing

@testable import FlightChannels

@Suite("Connection lifecycle — teardown, heartbeats", .timeLimit(.minutes(1)))
struct LifecycleTests {

    @Test("leave: reply, handler leave runs, fan-out stops for that socket")
    func explicitLeave() async throws {
        let harness = try Harness()
        let wire = try await harness.wire("/socket?token=alice")
        _ = try await wire.join("room:1")

        try wire.send(ref: "2", topic: "room:1", event: "flight:leave")
        #expect(try await wire.nextEnvelope()?.event == "flight:reply")
        #expect(await (try harness.events).waitFor { $0.contains("leave room:1 by alice") })

        // The membership is gone: events on the topic are refused…
        try wire.send(ref: "3", topic: "room:1", event: "echo")
        #expect(try await wire.nextEnvelope()?.payload == ["reason": "not_joined"])
        // …and its PubSub subscription ended.
        #expect(try harness.localPubSub.subscriberCount(for: "room:1") == 0)
        wire.close()
    }

    @Test("leaving a topic never joined is a named error")
    func leaveUnjoined() async throws {
        let harness = try Harness()
        let wire = try await harness.wire()
        try wire.send(ref: "1", topic: "room:1", event: "flight:leave")
        #expect(try await wire.nextEnvelope()?.payload == ["reason": "not_joined"])
        wire.close()
    }

    @Test("peer close: every channel leaves, subscriptions end, scope unwinds")
    func closeTearsDownAllChannels() async throws {
        let harness = try Harness()
        let wire = try await harness.wire("/socket?token=alice")
        _ = try await wire.join("room:1", ref: "1")
        _ = try await wire.join("room:2", ref: "2")
        #expect(try harness.localPubSub.subscriberCount(for: "room:1") == 1)

        wire.close()
        wire.socket.finishFromServer()
        await wire.socket.waitForServer()

        let events = try harness.events
        #expect(await events.waitFor {
            $0.contains("leave room:1 by alice") && $0.contains("leave room:2 by alice")
        })
        #expect(try harness.localPubSub.subscriberCount(for: "room:1") == 0)
        #expect(try harness.localPubSub.subscriberCount(for: "room:2") == 0)
    }

    @Test("flight:close: graceful teardown — ack flushed, then the close frame")
    func gracefulClose() async throws {
        let harness = try Harness()
        let wire = try await harness.wire("/socket?token=alice")
        _ = try await wire.join("room:1")

        try wire.send(ref: "9", topic: "flight", event: "flight:close")
        let ack = try await wire.nextEnvelope()
        #expect(ack == Envelope(ref: "9", topic: "flight", event: "flight:reply", payload: .object([:])))

        // nextEnvelope returns nil on the close frame / stream end.
        #expect(try await wire.nextEnvelope() == nil)
        #expect(await (try harness.events).waitFor { $0.contains("leave room:1 by alice") })
    }

    @Test("an undecodable frame closes with the protocol-violation code")
    func invalidEnvelopeCloses() async throws {
        let harness = try Harness()
        let wire = try await harness.wire()
        wire.socket.send("this is not an envelope")

        var closeCode: WebSocketCloseCode?
        while let frame = await wire.nextFrame() {
            if case .close(let code, _) = frame { closeCode = code; break }
        }
        #expect(closeCode == WebSocketCloseCode(ChannelCloseCode.protocolViolation))
    }

    @Test("a binary frame closes with 1003 — protocol v1 is JSON text")
    func binaryFrameCloses() async throws {
        let harness = try Harness()
        let wire = try await harness.wire()
        wire.socket.send(Data([0x01, 0x02]))

        var closeCode: WebSocketCloseCode?
        while let frame = await wire.nextFrame() {
            if case .close(let code, _) = frame { closeCode = code; break }
        }
        #expect(closeCode == .unacceptableData)
    }

    @Test("a silent socket is closed past the heartbeat timeout — and channels leave")
    func heartbeatTimeout() async throws {
        let harness = try Harness(heartbeatTimeoutSeconds: 0.15, checkIntervalSeconds: 0.03)
        let wire = try await harness.wire("/socket?token=alice")
        _ = try await wire.join("room:1")

        // Send nothing. The watchdog must close us.
        var closeCode: WebSocketCloseCode?
        while let frame = await wire.nextFrame() {
            if case .close(let code, _) = frame { closeCode = code; break }
        }
        #expect(closeCode == WebSocketCloseCode(ChannelCloseCode.heartbeatTimeout))
        #expect(await (try harness.events).waitFor { $0.contains("leave room:1 by alice") })
        #expect(try harness.localPubSub.subscriberCount(for: "room:1") == 0)
    }

    @Test("heartbeats keep an otherwise-quiet socket alive")
    func heartbeatKeepsAlive() async throws {
        let harness = try Harness(heartbeatTimeoutSeconds: 0.15, checkIntervalSeconds: 0.03)
        let wire = try await harness.wire()
        _ = try await wire.join("room:1")

        // Heartbeat at ~50ms for 400ms — several timeout windows.
        for beat in 0..<8 {
            try wire.send(ref: "hb\(beat)", topic: "flight", event: "flight:heartbeat")
            let reply = try await wire.nextEnvelope()
            #expect(reply?.ref == "hb\(beat)")
            try await Task.sleep(for: .milliseconds(50))
        }
        // Still alive and functional.
        try wire.send(ref: "9", topic: "room:1", event: "echo", payload: ["alive": true])
        #expect(try await wire.nextEnvelope()?.payload == ["alive": true])
        wire.close()
    }

    @Test("any inbound frame counts as liveness, not only heartbeats")
    func activityIsLiveness() async throws {
        let harness = try Harness(heartbeatTimeoutSeconds: 0.15, checkIntervalSeconds: 0.03)
        let wire = try await harness.wire()
        _ = try await wire.join("room:1")

        for n in 0..<8 {
            try wire.send(ref: "\(n)", topic: "room:1", event: "echo")
            _ = try await wire.nextEnvelope()
            try await Task.sleep(for: .milliseconds(50))
        }
        try wire.send(ref: "z", topic: "room:1", event: "echo")
        #expect(try await wire.nextEnvelope()?.ref == "z")
        wire.close()
    }
}

/// The bound the heartbeat watchdog cannot supply.
@Suite("Outbound write timeout", .timeLimit(.minutes(1)))
struct WriteTimeoutTests {

    /// A connection whose `send` never completes — the peer that reads
    /// nothing, so the TCP window never opens.
    private func stalledConnection() -> WebSocketConnection {
        WebSocketConnection(
            frames: AsyncStream { _ in },
            send: { _ in
                // Never resumed, and not cancellation-shaped on purpose:
                // `Task.sleep` would unwind on its own and prove nothing.
                await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
            },
            close: { _, _ in }
        )
    }

    @Test("a peer that never accepts a frame does not park the writer forever")
    func stalledWriteGivesUp() async throws {
        // A client that keeps *sending* heartbeats while never *reading* is
        // alive by the watchdog's definition — it counts inbound frames — so
        // the watchdog never fires and the writer sat in `connection.send`
        // indefinitely. Memory stayed bounded by the outbound queue; a task
        // and a connection leaked per socket, which is slow resource
        // exhaustion rather than fast.
        let started = ContinuousClock.now
        await #expect(throws: WriteTimedOut.self) {
            try await ChannelSocketHandler.send(
                "hello", over: stalledConnection(), within: .milliseconds(100))
        }
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test("nil means wait, for a deployment that wants that")
    func timeoutIsOptional() async throws {
        let connection = WebSocketConnection(
            frames: AsyncStream { _ in }, send: { _ in }, close: { _, _ in })
        try await ChannelSocketHandler.send("hello", over: connection, within: nil)
    }

    @Test("an ordinary send is unaffected by the bound")
    func healthySendSucceeds() async throws {
        let sent = Mutex<[String]>([])
        let connection = WebSocketConnection(
            frames: AsyncStream { _ in },
            send: { frame in
                if case .text(let text) = frame { sent.withLock { $0.append(text) } }
            },
            close: { _, _ in })
        try await ChannelSocketHandler.send("hello", over: connection, within: .seconds(30))
        #expect(sent.withLock { $0 } == ["hello"])
    }
}
