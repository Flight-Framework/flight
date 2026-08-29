import Synchronization
@_spi(FlightInternal) import FlightChannels
import FlightPresenceProtocol
import FlightPubSub
import struct Foundation.Data
import class Foundation.JSONEncoder
import Logging

/// Which failure-detection mode this deployment runs in —
/// decided once at freeze from what the container holds, logged loudly at
/// startup so nobody discovers the distinction from a bug report.
public enum PresenceMode: Sendable, Equatable, CustomStringConvertible {
    /// No distributed PubSub adapter: one node, node failure is not a
    /// distributed concern, no gossip at all.
    case singleNode
    /// A `PresenceMembershipMonitor` is registered (the SWIM adapter,
    ///): prompt, correct removal of a dead node's entries. The
    /// intended multi-node deployment mode.
    case membership
    /// A fan-out-only adapter (Valkey-style) and no membership signal:
    /// heartbeat-plus-expiry, the documented degraded mode —
    /// removal delayed up to the timeout, slow nodes may flap.
    case heartbeatExpiry

    public var description: String {
        switch self {
        case .singleNode: return "single-node"
        case .membership: return "membership-aware"
        case .heartbeatExpiry: return "heartbeat-expiry (degraded)"
        }
    }
}

/// The slice of `Socket` Presence touches — a seam so local semantics are
/// testable without standing up a WebSocket stack.
protocol PresenceSocket: Sendable {
    var id: String { get }
    func onTopicActivated(_ topic: String, perform: @escaping @Sendable () -> Void)
    func onTopicTerminated(_ topic: String, perform: @escaping @Sendable () -> Void)
    func pushReserved(topic: String, event: String, payload: JSONValue)
}

extension Socket: PresenceSocket {}

/// The presence engine: local tracking, the replicated CRDT state and
/// its gossip, replica liveness, and diff/state delivery to
/// clients. One actor — every mutation, local or gossiped, is
/// serialized here, which is what makes "compute the diff for exactly this
/// transition" trivial rather than racy.
///
/// Delivery split, load-bearing: **diffs and state pushes go through the
/// *local* PubSub only; gossip goes through the app's (possibly clustered)
/// PubSub.** Every node computes identical diffs from its own replica's
/// transitions, so broadcasting them cluster-wide would deliver every diff
/// N times. The gossip topic is the only presence traffic on the wire.
public actor PresenceTracker: Presence {

    public nonisolated let replica: PresenceReplicaID
    public nonisolated let mode: PresenceMode

    private let configuration: PresenceConfiguration
    private let localBus: LocalPubSub
    private let gossipBus: any PubSub
    private let logger: Logger
    private let liveClock = ContinuousClock()

    // MARK: - Replicated state

    private var counter: UInt64 = 0
    private var state = PresenceCRDTState()
    /// topic → live dots, maintained on every transition so `list` and
    /// state pushes never scan unrelated topics.
    private var topicIndex: [String: Set<PresenceDot>] = [:]

    // MARK: - Local connection bookkeeping

    private struct Membership: Hashable {
        let socketID: String
        let topic: String
    }

    /// (socket, topic) → key → the dot currently asserting it.
    private var localTracks: [Membership: [String: PresenceDot]] = [:]
    /// Memberships whose termination observer is registered — one observer
    /// per membership, re-registered after a leave/rejoin cycle.
    /// Which generation of each membership currently owns its cleanup.
    ///
    /// A membership is (socket, topic), and the same pair can end and begin
    /// again — a client leaving a room and rejoining it. `onTopicTerminated`
    /// fires a detached task, so that cleanup is unordered against a `track`
    /// that arrives immediately after: the rejoin could run first, and the
    /// *previous* membership's cleanup would then remove the entries the
    /// rejoin had just added. The user was back, and invisible, with the
    /// server believing they had left.
    ///
    /// The generation is what tells a cleanup whether it is still speaking
    /// for the membership it was registered by.
    private var membershipGeneration: [Membership: Int] = [:]
    private var generationCounter = 0

    /// Set the instant a membership's topic terminates, before the cleanup
    /// task has had a chance to run.
    ///
    /// The termination observer is synchronous and cannot touch actor state,
    /// so it flips this and spawns the cleanup. A `track` arriving in between
    /// can therefore *see* that the membership has ended, which is the one
    /// thing it could not do before: it found `localTracks` still populated,
    /// took the "update the existing meta" path, and left the stale cleanup
    /// holding a generation that still matched — so the cleanup ran and
    /// removed the rejoin.
    private var membershipEnded: [Membership: MembershipEndFlag] = [:]

    /// One diff waiting to reach the local bus.
    private struct QueuedDiff: Sendable {
        let topic: String
        let payload: Data
    }

    /// Diffs computed but not yet on the bus, in computation order.
    private var pendingDiffs: [QueuedDiff] = []
    /// How far `flushDiffs` has drained. See its comment: `removeFirst()`
    /// shifted the whole array per diff, on the actor every presence change
    /// goes through.
    private var pendingDiffsHead = 0

    // MARK: - Peer liveness

    private struct Liveness {
        var lastSeen: ContinuousClock.Instant
        var downSince: ContinuousClock.Instant?
    }

    private var peers: [PresenceReplicaID: Liveness] = [:]
    /// Membership mode: node *names* currently declared down. Gossip from
    /// them is ignored until the monitor declares them up again — the
    /// monitor is authoritative, resumed gossip alone is not.
    private var downNames: Set<String> = []

    public init(
        replica: PresenceReplicaID,
        mode: PresenceMode,
        configuration: PresenceConfiguration,
        localBus: LocalPubSub,
        gossipBus: any PubSub,
        logger: Logger = Logger(label: "flight.presence")
    ) {
        self.replica = replica
        self.mode = mode
        self.configuration = configuration
        self.localBus = localBus
        self.gossipBus = gossipBus
        self.logger = logger
    }

    // MARK: - Presence (the application surface)

    public func track(topic: String, key: String, payload: [String: String], socket: Socket) async {
        await track(topic: topic, key: key, payload: payload, presenceSocket: socket)
    }

    public func update(topic: String, key: String, payload: [String: String], socket: Socket) async {
        await update(topic: topic, key: key, payload: payload, presenceSocket: socket)
    }

    public func untrack(topic: String, key: String, socket: Socket) async {
        await untrack(topic: topic, key: key, socketID: socket.id)
    }

    public func sendState(topic: String, to socket: Socket) async {
        sendState(topic: topic, toPresenceSocket: socket)
    }

    public func list(topic: String) async -> [PresenceEntry] {
        let entries = visibleEntries(topic)
        return entries.keys.sorted().map { PresenceEntry(key: $0, metas: entries[$0]!) }
    }

    // MARK: - Socket-seam generic implementations (internal for tests)

    func track(topic: String, key: String, payload: [String: String], presenceSocket socket: some PresenceSocket) async {
        let payload = sanitized(payload)
        let membership = Membership(socketID: socket.id, topic: topic)

        // If the previous membership has ended but its cleanup has not run,
        // retire it now, in order, so this track begins a fresh one rather
        // than adding to a membership that is about to be swept.
        if membershipEnded[membership]?.hasEnded == true {
            await retireMembership(membership)
        }

        if let existing = localTracks[membership]?[key] {
            await replaceMeta(membership: membership, key: key, oldDot: existing, payload: payload)
        } else {
            counter += 1
            let dot = PresenceDot(replica: replica, counter: counter)
            let record = PresenceRecord(topic: topic, key: key, ref: "\(replica.boot)-\(counter)", payload: payload)
            let delta = state.add(record, at: dot)
            topicIndex[topic, default: []].insert(dot)
            localTracks[membership, default: [:]][key] = dot
            publishDiff(topic: topic, joins: [key: [meta(of: record)]], leaves: [:])
            await flushDiffs()
            await gossip(.delta(from: replica, state: delta))
        }

        // Registered *after* the state mutation: if the membership already
        // ended (a rare race), the observer fires immediately and the
        // cleanup runs after this call's mutations — never before them.
        registerCleanup(membership: membership, socket: socket)
    }

    func update(topic: String, key: String, payload: [String: String], presenceSocket socket: some PresenceSocket) async {
        let membership = Membership(socketID: socket.id, topic: topic)
        guard let existing = localTracks[membership]?[key] else {
            logger.warning(
                "presence update for an untracked meta ignored — track first",
                metadata: ["topic": "\(topic)", "key": "\(key)", "socket": "\(socket.id)"]
            )
            return
        }
        await replaceMeta(membership: membership, key: key, oldDot: existing, payload: sanitized(payload))
    }

    func untrack(topic: String, key: String, socketID: String) async {
        let membership = Membership(socketID: socketID, topic: topic)
        guard let dot = localTracks[membership]?[key] else { return }
        localTracks[membership]?.removeValue(forKey: key)
        if localTracks[membership]?.isEmpty == true { localTracks.removeValue(forKey: membership) }
        await removeLocalDots([dot], topic: topic)
    }

    func sendState(topic: String, toPresenceSocket socket: some PresenceSocket) {
        // Fires once the membership is fully established (join accepted,
        // PubSub pump subscribed — the Channels seam guarantees the
        // ordering), so the pushed state can never miss a diff published
        // in between; overlap is normalized by the client helpers.
        socket.onTopicActivated(topic) { [weak self] in
            guard let self else { return }
            Task { await self.pushState(topic: topic, to: socket) }
        }
    }

    // MARK: - Local mutation plumbing

    private func replaceMeta(membership: Membership, key: String, oldDot: PresenceDot, payload: [String: String]) async {
        guard let old = state.entries[oldDot] else {
            logger.error(
                "local track bookkeeping out of sync with CRDT state",
                metadata: ["topic": "\(membership.topic)", "key": "\(key)"]
            )
            return
        }
        counter += 1
        let dot = PresenceDot(replica: replica, counter: counter)
        // Same ref, new payload: on the wire this is a leave of the old
        // meta and a join of the new one for that same ref.
        let record = PresenceRecord(topic: membership.topic, key: key, ref: old.ref, payload: payload)
        let delta = state.replace(oldDot, with: record, at: dot)
        topicIndex[membership.topic]?.remove(oldDot)
        topicIndex[membership.topic, default: []].insert(dot)
        localTracks[membership]?[key] = dot
        publishDiff(
            topic: membership.topic,
            joins: [key: [meta(of: record)]],
            leaves: [key: [meta(of: old)]]
        )
        await flushDiffs()
        await gossip(.delta(from: replica, state: delta))
    }

    private func membershipEnded(socketID: String, topic: String, generation: Int) async {
        let membership = Membership(socketID: socketID, topic: topic)
        guard membershipGeneration[membership] == generation else {
            // A newer membership for this socket and topic replaced the one
            // this cleanup was registered by — the client rejoined before the
            // leave was processed. Removing now would erase the rejoin.
            logger.debug(
                "ignoring presence cleanup for a membership that has already been replaced",
                metadata: ["topic": "\(topic)", "socket": "\(socketID)"]
            )
            return
        }
        await retireMembership(membership)
    }

    /// Drops a membership's local state and publishes its leaves. Idempotent.
    private func retireMembership(_ membership: Membership) async {
        membershipGeneration.removeValue(forKey: membership)
        membershipEnded.removeValue(forKey: membership)
        guard let tracks = localTracks.removeValue(forKey: membership), !tracks.isEmpty else { return }
        await removeLocalDots(Array(tracks.values), topic: membership.topic)
    }

    private func removeLocalDots(_ dots: [PresenceDot], topic: String) async {
        var leaves: [String: [PresenceMeta]] = [:]
        for dot in dots.sorted() {
            guard let record = state.entries[dot] else { continue }
            leaves[record.key, default: []].append(meta(of: record))
        }
        let delta = state.remove(dots)
        for dot in dots { topicIndex[topic]?.remove(dot) }
        if topicIndex[topic]?.isEmpty == true { topicIndex.removeValue(forKey: topic) }
        guard !leaves.isEmpty else { return }
        publishDiff(topic: topic, joins: [:], leaves: leaves)
        await flushDiffs()
        await gossip(.delta(from: replica, state: delta))
    }

    /// Registers cleanup for a membership, if it does not already have one.
    ///
    /// Keyed on whether this membership currently has a generation rather
    /// than on a "already registered" set. A set keyed by (socket, topic)
    /// went stale across a leave/rejoin: the rejoin found the old entry
    /// present, skipped registering, and the new membership ended up with no
    /// cleanup at all — so its entries outlived the socket.
    ///
    /// Registering twice for one generation would be harmless anyway;
    /// `membershipEnded` is idempotent and generation-checked.
    private func registerCleanup(membership: Membership, socket: some PresenceSocket) {
        guard membershipGeneration[membership] == nil else { return }
        generationCounter += 1
        let generation = generationCounter
        membershipGeneration[membership] = generation
        let endFlag = MembershipEndFlag()
        membershipEnded[membership] = endFlag
        socket.onTopicTerminated(membership.topic) { [weak self] in
            // Flipped synchronously, so a `track` arriving before the task
            // below runs can see that this membership is over.
            endFlag.markEnded()
            guard let self else { return }
            Task {
                await self.membershipEnded(
                    socketID: membership.socketID,
                    topic: membership.topic,
                    generation: generation)
            }
        }
    }

    private func pushState(topic: String, to socket: some PresenceSocket) {
        socket.pushReserved(
            topic: topic,
            event: PresenceEvent.state,
            payload: PresenceWire.json(entries: visibleEntries(topic))
        )
    }

    private func sanitized(_ payload: [String: String]) -> [String: String] {
        var payload = payload
        if payload.removeValue(forKey: PresenceWire.refKey) != nil {
            logger.warning("presence payload key 'ref' is reserved and was dropped")
        }
        return payload
    }

    private func meta(of record: PresenceRecord) -> PresenceMeta {
        PresenceMeta(ref: record.ref, payload: record.payload)
    }

    // MARK: - Views

    private func isDown(_ replica: PresenceReplicaID) -> Bool {
        peers[replica]?.downSince != nil
    }

    private func visibleEntries(_ topic: String) -> [String: [PresenceMeta]] {
        var byKey: [String: [(PresenceDot, PresenceRecord)]] = [:]
        for dot in topicIndex[topic] ?? [] {
            guard !isDown(dot.replica), let record = state.entries[dot] else { continue }
            byKey[record.key, default: []].append((dot, record))
        }
        return byKey.mapValues { pairs in
            pairs.sorted { $0.0 < $1.0 }.map { meta(of: $0.1) }
        }
    }

    /// Diagnostic view: every replica currently contributing hidden or
    /// visible state, with liveness. For tests and (later) Actuator.
    public func knownPeers() -> [PresenceReplicaID: Bool] {
        peers.mapValues { $0.downSince == nil }
    }

    // MARK: - Gossip intake — driven by PresenceService

    func receiveGossip(_ raw: Message) async {
        let (decoded, unknownVersion) = PresenceGossipFrame.decode(raw.payload)
        guard let message = decoded else {
            if let unknownVersion {
                logger.warning(
                    "dropping presence gossip with unknown version",
                    metadata: ["version": "\(unknownVersion)"]
                )
            } else {
                logger.warning("dropping undecodable presence gossip payload")
            }
            return
        }
        let sender = message.sender
        guard sender != replica else { return }
        if mode == .membership, downNames.contains(sender.name) {
            logger.debug(
                "ignoring gossip from node the membership monitor holds down",
                metadata: ["node": "\(sender.name)"]
            )
            return
        }

        await touch(sender)

        switch message {
        case .delta(_, let delta), .snapshot(_, let delta):
            guard let delta = validated(delta, from: sender) else { return }
            await apply(delta)
        case .syncRequest:
            logger.debug("answering presence sync request", metadata: ["from": "\(sender)"])
            await gossipOwnSnapshot()
        }
    }

    /// Checks a frame against what a well-behaved sender can say, or drops it.
    ///
    /// The trust boundary is the PubSub bus, not this function: anything that
    /// can publish to the gossip topic is inside it, and no amount of
    /// validation here changes that (`Docs/presence.md`, "What this trusts").
    /// What these rules do is bound the damage a *buggy* peer can do — a node
    /// whose own state has gone wrong, or one running a version that means
    /// something different by the same bytes — which used to be "whatever it
    /// sent, merged".
    ///
    /// Both rules are things no correct sender ever violates, so neither can
    /// reject a legitimate frame:
    ///
    /// - A frame speaks only for its sender. `snapshot(of:)` carries own
    ///   entries; `add`/`remove` deltas carry own dots. An entry belonging to
    ///   a third replica means the sender is confused about whose state it
    ///   holds — and merging it lets one bad node speak for the whole cluster.
    /// - A frame is not unboundedly large. One node's own presences is a
    ///   number in the hundreds; ``PresenceConfiguration/maxEntriesPerFrame``
    ///   sits far above it.
    ///
    /// The context is checked separately, by `join(_:ownReplica:)`, which
    /// refuses a sender's claims about *this* replica's dots — that one is
    /// not a bound but a crash fix.
    private func validated(
        _ state: PresenceCRDTState, from sender: PresenceReplicaID
    ) -> PresenceCRDTState? {
        if let limit = configuration.maxEntriesPerFrame, state.entries.count > limit {
            logger.warning(
                "dropping oversized presence gossip frame",
                metadata: [
                    "replica": "\(sender)",
                    "entries": "\(state.entries.count)",
                    "limit": "\(limit)",
                ])
            return nil
        }
        if let foreign = state.entries.keys.first(where: { $0.replica != sender }) {
            logger.warning(
                "dropping presence gossip asserting another replica's entries",
                metadata: ["replica": "\(sender)", "asserted": "\(foreign.replica)"])
            return nil
        }
        return state
    }

    private func touch(_ sender: PresenceReplicaID) async {
        let now = liveClock.now
        if var liveness = peers[sender] {
            liveness.lastSeen = now
            let wasDown = liveness.downSince != nil
            liveness.downSince = nil
            peers[sender] = liveness
            if wasDown {
                logger.info("presence replica resumed gossip; restoring its entries", metadata: ["replica": "\(sender)"])
                await emitVisibility(of: sender, visible: true)
            }
        } else {
            logger.debug("discovered presence replica", metadata: ["replica": "\(sender)"])
            peers[sender] = Liveness(lastSeen: now, downSince: nil)
        }
    }

    private func apply(_ incoming: PresenceCRDTState) async {
        // `ownReplica:` — this is the wire path, and a frame claiming to have
        // observed *our* dots is malformed or hostile either way. Merging one
        // raised our version past our clock, so the next local `track` tripped
        // `add`'s monotonic-counter precondition and killed the process.
        let changes = state.join(incoming, ownReplica: replica)
        guard !changes.isEmpty else { return }

        var joins: [String: [String: [PresenceMeta]]] = [:]
        var leaves: [String: [String: [PresenceMeta]]] = [:]
        for (dot, record) in changes.added.sorted(by: { $0.0 < $1.0 }) {
            topicIndex[record.topic, default: []].insert(dot)
            // Kept although a frame only ever carries its sender's entries
            // and `touch(sender)` has just cleared the sender's down state,
            // which makes this unreachable through the gossip path today. It
            // is the invariant, not the caller, that makes it so — and this
            // is the one place a down replica's entries could otherwise be
            // announced as joins.
            guard !isDown(dot.replica) else { continue }
            joins[record.topic, default: [:]][record.key, default: []].append(meta(of: record))
        }
        for (dot, record) in changes.removed.sorted(by: { $0.0 < $1.0 }) {
            topicIndex[record.topic]?.remove(dot)
            if topicIndex[record.topic]?.isEmpty == true { topicIndex.removeValue(forKey: record.topic) }
            guard !isDown(dot.replica) else { continue }
            leaves[record.topic, default: [:]][record.key, default: []].append(meta(of: record))
        }

        for topic in Set(joins.keys).union(leaves.keys).sorted() {
            publishDiff(topic: topic, joins: joins[topic] ?? [:], leaves: leaves[topic] ?? [:])
        }
        await flushDiffs()
    }

    // MARK: - Liveness transitions — driven by PresenceService

    func membershipEvent(_ event: PresenceMembershipEvent) async {
        switch event {
        case .down(let name):
            logger.warning(
                "membership monitor declared node down; hiding its presences",
                metadata: ["node": "\(name)"]
            )
            downNames.insert(name)
            for (peer, liveness) in peers where peer.name == name && liveness.downSince == nil {
                // The monitor is authoritative here, not a silence timer, so
                // nothing about `lastSeen` should hold the decision back.
                await markDown(peer, silentSince: liveness.lastSeen, authoritative: true)
            }
        case .up(let name):
            logger.info("membership monitor declared node up", metadata: ["node": "\(name)"])
            downNames.remove(name)
            // Help the (re)joining node catch up without waiting a full
            // re-announce interval. Its own syncRequest covers the fresh-
            // boot case; this covers the network-partition heal.
            await gossipOwnSnapshot()
        }
    }

    /// One liveness pass: degraded-mode expiry and, in both
    /// clustered modes, the permdown purge.
    func sweep() async {
        let now = liveClock.now
        for (peer, liveness) in peers {
            if mode == .heartbeatExpiry,
                liveness.downSince == nil,
                now - liveness.lastSeen > configuration.downAfter
            {
                logger.warning(
                    "presence replica silent past down-after; hiding its entries (degraded mode)",
                    metadata: ["replica": "\(peer)", "down-after": "\(configuration.downAfter)"]
                )
                await markDown(peer, silentSince: liveness.lastSeen)
            }

            // Membership mode's backstop. The monitor is authoritative and
            // normally marks a dead node down long before this — reaching it
            // means the monitor did not, which is worth an error rather than
            // a shrug: without this branch the entries stayed visible
            // forever, and nothing anywhere said so.
            if mode == .membership,
                let fallback = configuration.membershipFallbackAfter,
                liveness.downSince == nil,
                now - liveness.lastSeen > fallback
            {
                logger.error(
                    """
                    presence replica silent far past the membership fallback and the monitor \
                    never reported it down; hiding its entries anyway
                    """,
                    metadata: [
                        "replica": "\(peer)",
                        "silent-for": "\(now - liveness.lastSeen)",
                        "fallback-after": "\(fallback)",
                    ]
                )
                await markDown(peer, silentSince: liveness.lastSeen)
            }
            if let downSince = peers[peer]?.downSince, now - downSince > configuration.permdownAfter {
                purge(peer)
            }
        }
    }

    /// - Parameter silentSince: The `lastSeen` the caller judged. `sweep`
    ///   iterates a value copy of `peers` and awaits mid-loop, so a peer that
    ///   gossiped during that suspension was still judged on a stale
    ///   `lastSeen` — hidden wrongly, then flapped back on its next frame.
    ///   Re-checking here, where the actor state is current, closes it.
    private func markDown(
        _ peer: PresenceReplicaID,
        silentSince: ContinuousClock.Instant,
        authoritative: Bool = false
    ) async {
        guard var liveness = peers[peer], liveness.downSince == nil else { return }
        guard authoritative || liveness.lastSeen <= silentSince else { return }
        liveness.downSince = liveClock.now
        peers[peer] = liveness
        await emitVisibility(of: peer, visible: false)
    }

    private func purge(_ peer: PresenceReplicaID) {
        logger.info("purging permanently-down presence replica", metadata: ["replica": "\(peer)"])
        let evicted = state.evict(peer)
        for (dot, record) in evicted {
            topicIndex[record.topic]?.remove(dot)
            if topicIndex[record.topic]?.isEmpty == true { topicIndex.removeValue(forKey: record.topic) }
        }
        peers.removeValue(forKey: peer)
    }

    /// Leave diffs when a replica goes down, join diffs when it comes
    /// back — its entries stay in the CRDT throughout (that is what makes
    /// the flap recoverable); only the visible view changes.
    private func emitVisibility(of peer: PresenceReplicaID, visible: Bool) async {
        var byTopic: [String: [String: [PresenceMeta]]] = [:]
        for dot in state.dots(of: peer).sorted() {
            guard let record = state.entries[dot] else { continue }
            byTopic[record.topic, default: [:]][record.key, default: []].append(meta(of: record))
        }
        for (topic, entries) in byTopic.sorted(by: { $0.key < $1.key }) {
            publishDiff(
                topic: topic,
                joins: visible ? entries : [:],
                leaves: visible ? [:] : entries
            )
        }
        await flushDiffs()
    }

    // MARK: - Periodic announcements — driven by PresenceService

    /// The heartbeat / anti-entropy tick: this replica's full own-entry
    /// snapshot. In degraded mode it is what keeps our entries alive on
    /// peers; in membership mode it repairs dropped deltas.
    func announce() async {
        await gossipOwnSnapshot()
    }

    /// Startup: ask the cluster for its state and announce our own —
    /// a fresh node converges without waiting a re-announce interval.
    func announceStartup() async {
        await gossip(.syncRequest(from: replica))
        await gossipOwnSnapshot()
    }

    private func gossipOwnSnapshot() async {
        await gossip(.snapshot(from: replica, state: state.snapshot(of: replica, clock: counter)))
    }

    // MARK: - Publishing

    private func gossip(_ message: PresenceGossipMessage) async {
        guard mode != .singleNode else { return }
        guard let data = PresenceGossipFrame.encode(message) else {
            logger.error("presence gossip failed to encode — dropped")
            return
        }
        let frame = Message(topic: PresenceGossip.topic, payload: data)

        // The leave that matters most is the one nobody asked for: a socket
        // going away takes its task with it, and the untrack that follows
        // runs already cancelled. A distributed adapter doing real I/O then
        // fails immediately — "distributed broadcast failed" in the log —
        // and every other node keeps showing that person until the heartbeat
        // expires. The local half succeeds, so nothing looks broken on the
        // node that lost them.
        //
        // So cleanup gets an uncancelled context, and is still awaited, which
        // is what keeps gossip in the order it was computed. Same shape as
        // Core's rollback path, for the same reason.
        guard Task.isCancelled else {
            await gossipBus.publish(frame)
            return
        }
        await Task.detached(priority: Task.currentPriority) { [gossipBus] in
            await gossipBus.publish(frame)
        }.value
    }

    /// Enqueues a diff for delivery, in the order it was computed.
    ///
    /// Publishing used to `await` inside the actor, which is a suspension
    /// point: another actor method could interleave between one diff being
    /// computed and it reaching the bus, so two diffs computed in order could
    /// be delivered in the other. A client applying a stale leave after a
    /// fresh join ended up with a ghost — and nothing repaired it, because
    /// the *server's* state was correct and a correct server emits no
    /// corrective diff.
    ///
    /// Enqueueing is synchronous, so the order diffs are computed in — which
    /// the actor already serializes — is the order they go out in. One pump
    /// task does the awaiting, outside the actor's mutable state.
    private func publishDiff(
        topic: String,
        joins: [String: [PresenceMeta]],
        leaves: [String: [PresenceMeta]]
    ) {
        guard !joins.isEmpty || !leaves.isEmpty else { return }
        let frame = BroadcastFrame(
            event: PresenceEvent.diff,
            payload: PresenceWire.diffJSON(joins: joins, leaves: leaves)
        )
        // One shared encoder, not one per diff: this runs on the actor that
        // serializes every client's presence change, and `JSONEncoder` is a
        // class with real setup cost.
        guard let data = try? Self.diffEncoder.encode(frame) else { return }
        pendingDiffs.append(QueuedDiff(topic: topic, payload: data))
    }

    /// Sends every queued diff, oldest first.
    ///
    /// The queue is what fixes the ordering; draining it here — rather than
    /// from a background task — is what keeps delivery where callers already
    /// expect it. A joining member's own join diff, for instance, must go out
    /// before that member subscribes, and deferring it to a pump delivered it
    /// afterwards, so they saw a join for themselves on top of their state.
    ///
    /// Re-entrant by design: if another method interleaves during the
    /// `await` and drains too, both loops take from the front of the same
    /// queue, so nothing is sent twice and nothing is sent out of order.
    private func flushDiffs() async {
        // `removeFirst()` shifts the whole array on every diff. An index into
        // it, with the storage reclaimed once drained, keeps the FIFO order
        // the queue exists for without the O(n) shift per element.
        while pendingDiffsHead < pendingDiffs.count {
            let queued = pendingDiffs[pendingDiffsHead]
            pendingDiffsHead += 1
            if pendingDiffsHead == pendingDiffs.count {
                pendingDiffs.removeAll(keepingCapacity: true)
                pendingDiffsHead = 0
            }
            await localBus.publish(Message(topic: queued.topic, payload: queued.payload))
        }
    }

    /// Shared by every diff this tracker encodes. See ``publishDiff``.
    private static let diffEncoder = JSONEncoder()
}

/// One membership's "the topic terminated" signal, readable synchronously
/// from the termination observer and from the actor.
final class MembershipEndFlag: Sendable {
    private let ended = Mutex(false)
    func markEnded() { ended.withLock { $0 = true } }
    var hasEnded: Bool { ended.withLock { $0 } }
}
