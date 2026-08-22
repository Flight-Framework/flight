import FlightPresenceProtocol
import FlightPubSub
import Testing
@testable import FlightPresence

/// Local tracking semantics (design §3, §10 "local semantics unit-test
/// directly"): multiple metas per key, correct leave only on the last
/// meta, diff generation, update-in-place, automatic cleanup through the
/// socket seam.
@Suite("PresenceTracker — local semantics (§2, §3, §7)", .timeLimit(.minutes(1)))
struct TrackerTests {

    private let topic = "room:42"

    @Test("track publishes a join diff and appears in list")
    func trackJoinDiff() async throws {
        let (tracker, bus) = makeTracker()
        let collector = DiffCollector(pubsub: bus, topic: topic)
        let socket = FakeSocket()

        await tracker.track(topic: topic, key: "user:7", payload: ["status": "online"], presenceSocket: socket)

        let list = await tracker.list(topic: topic)
        #expect(list.count == 1)
        #expect(list[0].key == "user:7")
        #expect(list[0].metas.count == 1)
        #expect(list[0].metas[0].payload == ["status": "online"])

        try await eventually("join diff published") { collector.diffs.count == 1 }
        let view = collector.replayedView()
        #expect(view.entries["user:7"]?.count == 1)
    }

    @Test("three tabs ⇒ three metas; closing one is not a leave of the key (§2)")
    func multipleMetasPerKey() async throws {
        let (tracker, bus) = makeTracker()
        let collector = DiffCollector(pubsub: bus, topic: topic)
        let sockets = [FakeSocket(), FakeSocket(), FakeSocket()]

        for (index, socket) in sockets.enumerated() {
            await tracker.track(topic: topic, key: "user:7", payload: ["tab": "\(index)"], presenceSocket: socket)
        }
        var list = await tracker.list(topic: topic)
        #expect(list.count == 1)
        #expect(list[0].metas.count == 3)

        // One tab closes: one meta leaves, the key remains present.
        sockets[0].close()
        try await eventually("first leave applied") {
            await tracker.list(topic: topic).first?.metas.count == 2
        }
        list = await tracker.list(topic: topic)
        #expect(list[0].key == "user:7")

        // Remaining tabs close: now — and only now — the key is gone.
        sockets[1].close()
        sockets[2].close()
        try await eventually("all metas removed") {
            await tracker.list(topic: topic).isEmpty
        }

        // The replayed client view agrees end to end.
        try await eventually("all diffs delivered") { collector.diffs.count == 6 }
        #expect(collector.replayedView().entries.isEmpty)
    }

    @Test("update keeps the ref and travels as leave-old + join-new for that ref (§6)")
    func updateInPlace() async throws {
        let (tracker, bus) = makeTracker()
        let collector = DiffCollector(pubsub: bus, topic: topic)
        let socket = FakeSocket()

        await tracker.track(topic: topic, key: "user:7", payload: ["status": "online"], presenceSocket: socket)
        let before = await tracker.list(topic: topic)[0].metas[0]

        await tracker.update(topic: topic, key: "user:7", payload: ["status": "away"], presenceSocket: socket)
        let after = await tracker.list(topic: topic)[0].metas[0]
        #expect(after.ref == before.ref)
        #expect(after.payload == ["status": "away"])

        try await eventually("update diff published") { collector.diffs.count == 2 }
        let updateDiff = collector.diffs[1]
        let leaves = PresenceWire.entries(from: updateDiff["leaves"] ?? .null)
        let joins = PresenceWire.entries(from: updateDiff["joins"] ?? .null)
        #expect(leaves["user:7"]?.map(\.ref) == [before.ref])
        #expect(leaves["user:7"]?.first?.payload == ["status": "online"])
        #expect(joins["user:7"]?.map(\.ref) == [before.ref])
        #expect(joins["user:7"]?.first?.payload == ["status": "away"])

        // And the client helper normalizes it to an in-place change.
        let view = collector.replayedView()
        #expect(view.entries["user:7"]?.count == 1)
        #expect(view.entries["user:7"]?.first?.payload == ["status": "away"])
    }

    @Test("re-tracking the same (socket, topic, key) replaces the meta, never duplicates")
    func retrackReplaces() async throws {
        let (tracker, _) = makeTracker()
        let socket = FakeSocket()

        await tracker.track(topic: topic, key: "user:7", payload: ["status": "a"], presenceSocket: socket)
        await tracker.track(topic: topic, key: "user:7", payload: ["status": "b"], presenceSocket: socket)

        let list = await tracker.list(topic: topic)
        #expect(list[0].metas.count == 1)
        #expect(list[0].metas[0].payload == ["status": "b"])
    }

    @Test("update of an untracked meta is a warned no-op")
    func updateUntracked() async throws {
        let (tracker, bus) = makeTracker()
        let collector = DiffCollector(pubsub: bus, topic: topic)
        let socket = FakeSocket()

        await tracker.update(topic: topic, key: "user:7", payload: ["status": "away"], presenceSocket: socket)
        let list = await tracker.list(topic: topic)
        #expect(list.isEmpty)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(collector.diffs.isEmpty)
    }

    @Test("untrack removes one meta explicitly and publishes its leave")
    func explicitUntrack() async throws {
        let (tracker, bus) = makeTracker()
        let collector = DiffCollector(pubsub: bus, topic: topic)
        let socket = FakeSocket()

        await tracker.track(topic: topic, key: "user:7", payload: [:], presenceSocket: socket)
        await tracker.untrack(topic: topic, key: "user:7", socketID: socket.id)

        #expect(await tracker.list(topic: topic).isEmpty)
        try await eventually("leave diff published") { collector.diffs.count == 2 }
    }

    @Test("leaving one topic leaves the socket's other topics tracked (§7)")
    func perTopicCleanup() async throws {
        let (tracker, _) = makeTracker()
        let socket = FakeSocket()

        await tracker.track(topic: "room:1", key: "user:7", payload: [:], presenceSocket: socket)
        await tracker.track(topic: "room:2", key: "user:7", payload: [:], presenceSocket: socket)

        socket.terminate("room:1")
        try await eventually("room:1 untracked") { await tracker.list(topic: "room:1").isEmpty }
        #expect(await tracker.list(topic: "room:2").count == 1)
    }

    @Test("a leave/rejoin cycle re-registers cleanup — the second leave untracks too")
    func rejoinCycleCleanup() async throws {
        let (tracker, _) = makeTracker()
        let socket = FakeSocket()

        await tracker.track(topic: topic, key: "user:7", payload: [:], presenceSocket: socket)
        socket.terminate(topic)
        try await eventually("first cycle untracked") { await tracker.list(topic: topic).isEmpty }

        await tracker.track(topic: topic, key: "user:7", payload: [:], presenceSocket: socket)
        #expect(await tracker.list(topic: topic).count == 1)
        socket.terminate(topic)
        try await eventually("second cycle untracked") { await tracker.list(topic: topic).isEmpty }
    }

    @Test("tracking against an already-closed socket cleans itself up (§7 race)")
    func trackAfterClose() async throws {
        let (tracker, _) = makeTracker()
        let socket = FakeSocket()
        socket.close()

        await tracker.track(topic: topic, key: "user:7", payload: [:], presenceSocket: socket)
        try await eventually("ghost cleaned up") { await tracker.list(topic: topic).isEmpty }
    }

    @Test("the reserved 'ref' payload key is dropped (§2)")
    func reservedRefKey() async throws {
        let (tracker, _) = makeTracker()
        let socket = FakeSocket()

        await tracker.track(topic: topic, key: "user:7", payload: ["ref": "spoofed", "ok": "yes"], presenceSocket: socket)
        let meta = await tracker.list(topic: topic)[0].metas[0]
        #expect(meta.payload == ["ok": "yes"])
        #expect(meta.ref != "spoofed")
    }

    @Test("sendState pushes flight:presence_state once the membership is active (§6)")
    func sendStateWaitsForActivation() async throws {
        let (tracker, _) = makeTracker()
        let watcher = FakeSocket()
        let member = FakeSocket()

        await tracker.track(topic: topic, key: "user:7", payload: ["status": "online"], presenceSocket: member)

        // Registered before the join completes: nothing pushed yet.
        await tracker.sendState(topic: topic, toPresenceSocket: watcher)
        #expect(watcher.pushes.isEmpty)

        // The Channels seam reports the membership established.
        watcher.activate(topic)
        try await eventually("state pushed") { watcher.pushes.count == 1 }
        let push = watcher.pushes[0]
        #expect(push.event == PresenceEvent.state)
        #expect(push.topic == topic)
        #expect(metas(in: push.payload, key: "user:7").count == 1)
    }

    @Test("sendState on an already-active membership pushes immediately")
    func sendStateImmediate() async throws {
        let (tracker, _) = makeTracker()
        let socket = FakeSocket()
        socket.activate(topic)

        await tracker.sendState(topic: topic, toPresenceSocket: socket)
        try await eventually("state pushed") { socket.pushes.count == 1 }
        #expect(socket.pushes[0].payload == .object([:]))  // empty topic is a real message
    }

    @Test("list is per-topic and sorted by key")
    func listIsolationAndOrder() async throws {
        let (tracker, _) = makeTracker()
        let socket = FakeSocket()

        await tracker.track(topic: "room:1", key: "zed", payload: [:], presenceSocket: socket)
        await tracker.track(topic: "room:1", key: "amy", payload: [:], presenceSocket: socket)
        await tracker.track(topic: "room:2", key: "bob", payload: [:], presenceSocket: socket)

        let list = await tracker.list(topic: "room:1")
        #expect(list.map(\.key) == ["amy", "zed"])
        #expect(await tracker.list(topic: "room:3").isEmpty)
    }
}
