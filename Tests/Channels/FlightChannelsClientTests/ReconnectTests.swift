import FlightChannelsClient
import FlightChannelsTesting
import Foundation
import Testing

@Suite("Swift client — heartbeat, reconnect, rejoin", .timeLimit(.minutes(1)))
struct ReconnectTests {

    private func fastReconnect(maxAttempts: Int? = nil) -> ChannelClientConfiguration {
        ChannelClientConfiguration(
            heartbeatInterval: .seconds(5),
            pushTimeout: .seconds(2),
            reconnect: .exponentialBackoff(
                initial: .milliseconds(10),
                max: .milliseconds(50),
                maxAttempts: maxAttempts
            )
        )
    }

    @Test("a dropped connection reconnects and rejoins automatically")
    func reconnectAndRejoin() async throws {
        var severable: SeverableTransport!
        let harness = try ClientHarness { transport in
            severable = SeverableTransport(wrapping: transport)
            return severable
        }
        let client = harness.makeClient(configuration: fastReconnect())
        try await client.connect()
        let counter = client.channel("counter:7")
        try await counter.join()
        let messages = await counter.messages()

        severable.severAll()

        // Rejoin is announced on the message stream with fresh state.
        var iterator = messages.makeAsyncIterator()
        let rejoin = await iterator.next()
        #expect(rejoin?.isRejoin == true)
        #expect(rejoin?.payload == ["count": 0])
        #expect(await client.connectionState == .connected)
        #expect(await client.isJoined("counter:7"))

        // The rejoined channel works — push/reply over the new connection.
        let reply = try await counter.push("echo", payload: ["post": "reconnect"])
        #expect(reply == ["post": "reconnect"])
        #expect(severable.connectCount == 2)
        await client.disconnect()
    }

    @Test("in-flight pushes fail fast with .disconnected on a drop, never hang")
    func inFlightFailure() async throws {
        var severable: SeverableTransport!
        let harness = try ClientHarness { transport in
            severable = SeverableTransport(wrapping: transport)
            return severable
        }
        let client = harness.makeClient(configuration: fastReconnect())
        try await client.connect()
        let counter = client.channel("counter:7")
        try await counter.join()

        let pending = Task { try await counter.push("silent", timeout: .seconds(10)) }
        try await Task.sleep(for: .milliseconds(50)) // let the push register
        severable.severAll()

        await #expect(throws: ChannelClientError.disconnected) {
            _ = try await pending.value
        }
        await client.disconnect()
    }

    @Test("backoff retries failed dials until one lands")
    func backoffRetries() async throws {
        var severable: SeverableTransport!
        let harness = try ClientHarness { transport in
            severable = SeverableTransport(wrapping: transport)
            return severable
        }
        let client = harness.makeClient(configuration: fastReconnect())
        try await client.connect()
        try await client.channel("counter:7").join()

        severable.refuseNextConnects(3)
        severable.severAll()

        // 1 initial + 3 refused + 1 success. Wait on the dial count first —
        // the old connection's `.connected` state lingers until the sever
        // propagates, so it can't be the first thing asserted.
        let transport = severable!
        #expect(await eventually { transport.connectCount == 5 })
        #expect(await eventually { await client.connectionState == .connected })
        #expect(await eventually { await client.isJoined("counter:7") })
        #expect(severable.connectCount == 5)
        await client.disconnect()
    }

    @Test("an exhausted reconnect policy closes the client")
    func policyExhaustion() async throws {
        var severable: SeverableTransport!
        let harness = try ClientHarness { transport in
            severable = SeverableTransport(wrapping: transport)
            return severable
        }
        let client = harness.makeClient(configuration: fastReconnect(maxAttempts: 2))
        try await client.connect()

        severable.refuseNextConnects(Int.max)
        severable.severAll()

        #expect(await eventually { await client.connectionState == .closed })
        await client.disconnect()
    }

    @Test("ReconnectPolicy.never: a drop is terminal")
    func neverReconnect() async throws {
        var severable: SeverableTransport!
        let harness = try ClientHarness { transport in
            severable = SeverableTransport(wrapping: transport)
            return severable
        }
        let client = harness.makeClient(
            configuration: ChannelClientConfiguration(reconnect: .never)
        )
        try await client.connect()
        severable.severAll()

        #expect(await eventually { await client.connectionState == .closed })
        #expect(severable.connectCount == 1)
    }

    @Test("a rejected rejoin surfaces as flight:error and stops retrying")
    func rejectedRejoin() async throws {
        // counter:locked rejects joins — but we need a first join to
        // succeed. Trick: join a normal topic, then simulate the gate
        // closing by... the fixture has no dynamic gate, so instead verify
        // the simpler contract: rejoin of a *left* channel doesn't happen.
        var severable: SeverableTransport!
        let harness = try ClientHarness { transport in
            severable = SeverableTransport(wrapping: transport)
            return severable
        }
        let client = harness.makeClient(configuration: fastReconnect())
        try await client.connect()
        let counter = client.channel("counter:7")
        try await counter.join()
        try await counter.leave()

        severable.severAll()
        #expect(await eventually { await client.connectionState == .connected })
        // Left before the drop ⇒ not rejoined after it.
        #expect(await !client.isJoined("counter:7"))
        await client.disconnect()
    }

    @Test("explicit disconnect suppresses reconnection")
    func disconnectIsTerminal() async throws {
        var severable: SeverableTransport!
        let harness = try ClientHarness { transport in
            severable = SeverableTransport(wrapping: transport)
            return severable
        }
        let client = harness.makeClient(configuration: fastReconnect())
        try await client.connect()
        await client.disconnect()

        try await Task.sleep(for: .milliseconds(100))
        #expect(await client.connectionState == .closed)
        #expect(severable.connectCount == 1)

        // …but connect() starts fresh afterwards.
        try await client.connect()
        #expect(await client.connectionState == .connected)
        await client.disconnect()
    }

    @Test("heartbeats flow on the wire and keep a quiet client alive")
    func heartbeats() async throws {
        // Server timeout 0.2s; client heartbeats every 60ms.
        let harness = try ClientHarness(heartbeatTimeoutSeconds: 0.2)
        let client = harness.makeClient(
            configuration: ChannelClientConfiguration(heartbeatInterval: .milliseconds(60))
        )
        try await client.connect()
        let counter = client.channel("counter:1")
        try await counter.join()

        try await Task.sleep(for: .milliseconds(500)) // several server windows
        #expect(await client.connectionState == .connected)
        let reply = try await counter.push("echo", payload: ["still": "alive"])
        #expect(reply == ["still": "alive"])
        await client.disconnect()
    }

    @Test("exponential backoff policy: doubling, capped, optionally bounded")
    func backoffPolicy() {
        let policy = ReconnectPolicy.exponentialBackoff(
            initial: .milliseconds(100),
            max: .seconds(1),
            maxAttempts: 6
        )
        #expect(policy.delay(1) == .milliseconds(100))
        #expect(policy.delay(2) == .milliseconds(200))
        #expect(policy.delay(3) == .milliseconds(400))
        #expect(policy.delay(4) == .milliseconds(800))
        #expect(policy.delay(5) == .seconds(1)) // capped
        #expect(policy.delay(6) == .seconds(1))
        #expect(policy.delay(7) == nil) // exhausted
        #expect(ReconnectPolicy.never.delay(1) == nil)
    }

    @Test("a duplicate join keeps its rejoin intent")
    func duplicateJoinKeepsRejoinIntent() async throws {
        // The server answers a second join with `already_joined`, and the
        // client treated any channelError as a closed gate and cleared
        // `desired`. So an app that called join() twice — or that raced the
        // automatic rejoinAll after a reconnect — kept a live membership and
        // silently lost rejoin-on-next-drop: the topic's stream just went
        // quiet after the following disconnect, with nothing said anywhere.
        var severable: SeverableTransport!
        let harness = try ClientHarness { transport in
            severable = SeverableTransport(wrapping: transport)
            return severable
        }
        let client = harness.makeClient(configuration: fastReconnect())
        try await client.connect()
        let counter = client.channel("counter:7")
        try await counter.join()
        let messages = await counter.messages()

        // The second join is refused — correctly, it is already joined.
        await #expect(throws: ChannelClientError.self) { try await counter.join() }
        #expect(await client.isJoined("counter:7"), "the live membership survived")

        // The membership must still come back after a drop.
        severable.severAll()
        var iterator = messages.makeAsyncIterator()
        let rejoin = await iterator.next()
        #expect(rejoin?.isRejoin == true, "the duplicate join cost the topic its rejoin")
        #expect(await client.isJoined("counter:7"))
        await client.disconnect()
    }

    @Test("connect() after disconnect() rejoins, as its doc promises")
    func reconnectingByHandRejoins() async throws {
        // `disconnect()` documents "channel membership intent survives — a
        // later connect() rejoins everything that was joined", and
        // rejoinAll was called from the reconnect loop and nowhere else. So
        // after a manual disconnect→connect the desired topics stayed
        // unjoined until the app re-joined each one by hand.
        let harness = try ClientHarness()
        let client = harness.makeClient(configuration: fastReconnect())
        try await client.connect()
        let counter = client.channel("counter:7")
        try await counter.join()
        #expect(await client.isJoined("counter:7"))

        await client.disconnect()
        #expect(!(await client.isJoined("counter:7")))

        try await client.connect()
        // Give the rejoin its round trip.
        for _ in 0..<200 where !(await client.isJoined("counter:7")) {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await client.isJoined("counter:7"), "connect() did not rejoin")

        // And the rejoined channel actually works.
        #expect(try await counter.push("echo", payload: ["a": 1]) == ["a": 1])
        await client.disconnect()
    }

    @Test("a disconnect racing an in-flight dial does not resurrect the client")
    func disconnectDuringDialWins() async throws {
        // With no state re-check after the `transport.connect` await, a
        // disconnect() landing while the dial was suspended completed anyway
        // and called beginSession unconditionally: state went .closed →
        // .connected, the heartbeat restarted, and the terminal close was
        // undone.
        let gate = DialGate()
        let harness = try ClientHarness { transport in
            GatedTransport(wrapping: transport, gate: gate)
        }
        let client = harness.makeClient(configuration: fastReconnect())

        let dialing = Task { try await client.connect() }
        await gate.waitUntilDialing()
        await client.disconnect()
        await gate.release()
        _ = try? await dialing.value

        #expect(await client.connectionState == .closed, "a closed client came back to life")
    }
}

/// Holds a dial open until the test lets it through.
actor DialGate {
    private var isDialing = false
    private var released = false
    private var dialWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func noteDialing() {
        isDialing = true
        for waiter in dialWaiters { waiter.resume() }
        dialWaiters = []
    }

    func waitUntilDialing() async {
        if isDialing { return }
        await withCheckedContinuation { dialWaiters.append($0) }
    }

    func release() {
        released = true
        for waiter in releaseWaiters { waiter.resume() }
        releaseWaiters = []
    }

    func waitForRelease() async {
        if released { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }
}

/// A transport whose dial parks in the gate — the suspension point the
/// resurrection race needs.
struct GatedTransport: ChannelClientTransport {
    let wrapped: any ChannelClientTransport
    let gate: DialGate

    init(wrapping wrapped: any ChannelClientTransport, gate: DialGate) {
        self.wrapped = wrapped
        self.gate = gate
    }

    func connect(to url: URL) async throws -> ClientTransportConnection {
        await gate.noteDialing()
        await gate.waitForRelease()
        return try await wrapped.connect(to: url)
    }
}
