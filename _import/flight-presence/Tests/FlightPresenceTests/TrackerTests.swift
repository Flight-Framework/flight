import FlightPresenceProtocol
import FlightPubSub
import Testing
@testable import FlightPresence

/// Local tracking semantics (design, "local semantics unit-test
/// directly"): multiple metas per key, correct leave only on the last
/// meta, diff generation, update-in-place, automatic cleanup through the
/// socket seam.
@Suite("PresenceTracker — local semantics", .timeLimit(.minutes(1)))
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

    @Test("three tabs ⇒ three metas; closing one is not a leave of the key")
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

    @Test("update keeps the ref and travels as leave-old + join-new for that ref")
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

    @Test("leaving one topic leaves the socket's other topics tracked")
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

    @Test("tracking against an already-closed socket cleans itself up")
    func trackAfterClose() async throws {
        let (tracker, _) = makeTracker()
        let socket = FakeSocket()
        socket.close()

        await tracker.track(topic: topic, key: "user:7", payload: [:], presenceSocket: socket)
        try await eventually("ghost cleaned up") { await tracker.list(topic: topic).isEmpty }
    }

    @Test("the reserved 'ref' payload key is dropped")
    func reservedRefKey() async throws {
        let (tracker, _) = makeTracker()
        let socket = FakeSocket()

        await tracker.track(topic: topic, key: "user:7", payload: ["ref": "spoofed", "ok": "yes"], presenceSocket: socket)
        let meta = await tracker.list(topic: topic)[0].metas[0]
        #expect(meta.payload == ["ok": "yes"])
        #expect(meta.ref != "spoofed")
    }

    @Test("sendState pushes flight:presence_state once the membership is active")
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

/// Leaving a topic and rejoining it before the leave has been processed.
@Suite("Leave then rejoin")
struct LeaveRejoinRaceTests {

    @Test("a rejoin is not erased by the previous membership's cleanup")
    func rejoinSurvivesStaleCleanup() async throws {
        // `onTopicTerminated` fires a detached task, so the cleanup for a
        // leave is unordered against a `track` arriving right behind it. When
        // the rejoin won that race, the previous membership's cleanup removed
        // the entries it had just added: the user was back, and invisible,
        // with the server believing they had left. Nothing corrected it.
        let (tracker, _) = makeTracker()
        let socket = FakeSocket(id: "s1")
        socket.activate("room:1")

        await tracker.track(topic: "room:1", key: "amy", payload: [:], presenceSocket: socket)
        #expect(await tracker.list(topic: "room:1").map(\.key) == ["amy"])

        // The leave fires its observer — the cleanup task is now pending.
        socket.terminate("room:1")

        // The rejoin lands before that task gets to run. Tracking on the same
        // socket and topic is exactly the shape a client reconnecting into
        // the same room produces.
        socket.activate("room:1")
        await tracker.track(topic: "room:1", key: "amy", payload: ["v": "2"], presenceSocket: socket)

        // Let the stale cleanup run.
        try await Task.sleep(for: .milliseconds(100))

        let entries = await tracker.list(topic: "room:1")
        #expect(entries.map(\.key) == ["amy"], "the rejoin must survive the previous cleanup")
        #expect(entries.first?.metas.first?.payload["v"] == "2")
    }

    @Test("the rejoined membership still cleans up when it ends")
    func rejoinedMembershipStillCleansUp() async throws {
        // The old dedupe was keyed on (socket, topic) and went stale across a
        // leave/rejoin: the rejoin found the entry present, skipped
        // registering, and the new membership ended up with no cleanup at
        // all — so its entries outlived the socket entirely.
        let (tracker, _) = makeTracker()
        let socket = FakeSocket(id: "s1")
        socket.activate("room:1")

        await tracker.track(topic: "room:1", key: "amy", payload: [:], presenceSocket: socket)
        socket.terminate("room:1")
        socket.activate("room:1")
        await tracker.track(topic: "room:1", key: "amy", payload: [:], presenceSocket: socket)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await tracker.list(topic: "room:1").map(\.key) == ["amy"])

        // Now end it for real.
        socket.terminate("room:1")
        try await Task.sleep(for: .milliseconds(100))
        #expect(
            await tracker.list(topic: "room:1").isEmpty,
            "the rejoined membership must have its own cleanup")
    }
}

/// Diffs reach clients in the order the server computed them.
@Suite("Diff ordering")
struct DiffOrderingTests {

    @Test("concurrent mutations produce diffs in computation order")
    func diffsArriveInOrder() async throws {
        // Publishing used to `await` inside the actor — a suspension point,
        // so another method could interleave between a diff being computed
        // and it reaching the bus, and two diffs computed in order could be
        // delivered in the other. A client applying a stale leave after a
        // fresh join kept a ghost, and nothing repaired it: the *server's*
        // state was right, and a correct server emits no corrective diff.
        let (tracker, bus) = makeTracker()
        let collector = DiffCollector(pubsub: bus, topic: "room:1")

        // Many sockets joining and leaving concurrently: every interleaving
        // the actor allows, exercised at once.
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<20 {
                group.addTask {
                    let socket = FakeSocket(id: "s\(index)")
                    socket.activate("room:1")
                    await tracker.track(
                        topic: "room:1", key: "user\(index)", payload: [:],
                        presenceSocket: socket)
                    socket.terminate("room:1")
                }
            }
        }
        try await eventually("all joins and leaves observed") { collector.diffs.count == 40 }

        // Whatever order the interleavings produced, applying the diffs in
        // arrival order must land on what the server actually holds.
        var view = PresenceSync()
        for diff in collector.diffs {
            _ = view.applyDiff(diff)
        }
        let server = await tracker.list(topic: "room:1")
        #expect(
            view.list.map(\.key).sorted() == server.map(\.key).sorted(),
            "client view \(view.list.map(\.key).sorted()) diverged from server \(server.map(\.key).sorted())")
    }

    @Test("a join and its leave never arrive reversed")
    func joinLeaveOrderHolds() async throws {
        let (tracker, bus) = makeTracker()
        let collector = DiffCollector(pubsub: bus, topic: "room:1")
        let socket = FakeSocket(id: "s1")
        socket.activate("room:1")

        await tracker.track(topic: "room:1", key: "amy", payload: [:], presenceSocket: socket)
        socket.terminate("room:1")
        // Wait for both diffs rather than a fixed delay: under a loaded test
        // run the leave can take longer than any sleep worth hard-coding.
        try await eventually("join and leave diffs observed") { collector.diffs.count == 2 }

        var view = PresenceSync()
        for diff in collector.diffs { _ = view.applyDiff(diff) }
        #expect(view.list.isEmpty, "the leave must be applied after the join, not before it")
    }
}
