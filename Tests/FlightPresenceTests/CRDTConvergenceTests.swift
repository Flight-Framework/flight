import Testing
@testable import FlightPresence

/// The §10 property suite: CRDT convergence asserted as a *property*, not
/// by example. Random sequences of track/untrack/update are generated
/// across simulated replicas; their deltas are applied to every other
/// replica in different orders, with duplication and (in the repair
/// variant) drops healed by snapshots — and every replica must converge to
/// the identical state. That is precisely the commutativity/associativity/
/// idempotence claim of §4; every failure message carries the seed that
/// reproduces it.
@Suite("CRDT convergence (§4, §10)", .timeLimit(.minutes(2)))
struct CRDTConvergenceTests {

    // MARK: - Simulated replica

    /// One node's tracker reduced to its CRDT half: performs local ops in
    /// causal order, records the delta each op produced.
    private final class SimulatedReplica {
        let id: PresenceReplicaID
        var state = PresenceCRDTState()
        var counter: UInt64 = 0
        var deltas: [PresenceCRDTState] = []
        var liveDots: [PresenceDot] = []

        init(_ name: String) {
            self.id = PresenceReplicaID(name: name, boot: "boot-\(name)")
        }

        func randomOp(using rng: inout SplitMix64) {
            let keys = ["u1", "u2", "u3", "u4", "u5"]
            let topics = ["room:1", "room:2"]
            let roll = UInt64.random(in: 0..<100, using: &rng)
            switch liveDots.isEmpty ? 0 : roll {
            case ..<55:  // add
                counter += 1
                let dot = PresenceDot(replica: id, counter: counter)
                let record = PresenceRecord(
                    topic: topics.randomElement(using: &rng)!,
                    key: keys.randomElement(using: &rng)!,
                    ref: "\(id.boot)-\(counter)",
                    payload: ["n": "\(counter)"]
                )
                deltas.append(state.add(record, at: dot))
                liveDots.append(dot)
            case ..<80:  // remove
                let index = Int.random(in: 0..<liveDots.count, using: &rng)
                let dot = liveDots.remove(at: index)
                deltas.append(state.remove([dot]))
            default:  // update in place
                let index = Int.random(in: 0..<liveDots.count, using: &rng)
                let old = liveDots[index]
                let record = state.entries[old]!
                counter += 1
                let dot = PresenceDot(replica: id, counter: counter)
                let updated = PresenceRecord(
                    topic: record.topic, key: record.key, ref: record.ref,
                    payload: ["n": "\(counter)"]
                )
                deltas.append(state.replace(old, with: updated, at: dot))
                liveDots[index] = dot
            }
        }

        func snapshot() -> PresenceCRDTState {
            state.snapshot(of: id, clock: counter)
        }
    }

    private func run(
        seed: UInt64,
        opsPerReplica: Int,
        dropRate: Int,
        duplicateRate: Int,
        healWithSnapshots: Bool
    ) {
        var rng = SplitMix64(seed: seed)
        let replicas = [SimulatedReplica("a"), SimulatedReplica("b"), SimulatedReplica("c")]

        for replica in replicas {
            for _ in 0..<opsPerReplica {
                replica.randomOp(using: &rng)
            }
        }

        // Each receiver gets every other replica's deltas in its own
        // shuffled order, with duplicates, and (optionally) drops healed
        // by a final snapshot inserted at a random position — join order
        // must not matter, so the snapshot need not come last.
        for receiver in replicas {
            var incoming: [PresenceCRDTState] = []
            for origin in replicas where origin !== receiver {
                for delta in origin.deltas {
                    if dropRate > 0, UInt64.random(in: 0..<100, using: &rng) < dropRate {
                        continue  // lost gossip (at-most-once, PubSub §8)
                    }
                    incoming.append(delta)
                    if UInt64.random(in: 0..<100, using: &rng) < duplicateRate {
                        incoming.append(delta)  // duplicated gossip
                    }
                }
                if healWithSnapshots {
                    incoming.append(origin.snapshot())
                }
            }
            incoming.shuffle(using: &rng)
            for delta in incoming {
                receiver.state.join(delta)
            }
        }

        let reference = replicas[0].state
        for replica in replicas.dropFirst() {
            #expect(
                replica.state == reference,
                "replicas diverged (seed \(seed)): \(replica.id) holds \(replica.state.entries.count) entries, \(replicas[0].id) holds \(reference.entries.count)"
            )
        }
    }

    @Test(
        "replicas converge under reordered + duplicated delta gossip",
        arguments: (0..<40).map { UInt64($0) }
    )
    func convergenceWithReorderingAndDuplication(seed: UInt64) {
        run(seed: seed, opsPerReplica: 60, dropRate: 0, duplicateRate: 25, healWithSnapshots: false)
    }

    @Test(
        "replicas converge under dropped gossip once snapshots repair it — in any order",
        arguments: (100..<140).map { UInt64($0) }
    )
    func convergenceWithDropsHealedBySnapshots(seed: UInt64) {
        run(seed: seed, opsPerReplica: 60, dropRate: 30, duplicateRate: 15, healWithSnapshots: true)
    }

    @Test("join is commutative and idempotent on random full states", arguments: (200..<220).map { UInt64($0) })
    func joinAlgebra(seed: UInt64) {
        var rng = SplitMix64(seed: seed)
        let a = SimulatedReplica("a")
        let b = SimulatedReplica("b")
        for _ in 0..<40 {
            a.randomOp(using: &rng)
            b.randomOp(using: &rng)
        }

        var ab = a.state
        ab.join(b.state)
        var ba = b.state
        ba.join(a.state)
        #expect(ab == ba, "join not commutative (seed \(seed))")

        var again = ab
        again.join(b.state)
        again.join(a.state)
        #expect(again == ab, "join not idempotent (seed \(seed))")
    }

    @Test("join is associative on random full states", arguments: (300..<320).map { UInt64($0) })
    func joinAssociativity(seed: UInt64) {
        var rng = SplitMix64(seed: seed)
        let replicas = [SimulatedReplica("a"), SimulatedReplica("b"), SimulatedReplica("c")]
        for replica in replicas {
            for _ in 0..<30 { replica.randomOp(using: &rng) }
        }

        // (a ⊔ b) ⊔ c
        var left = replicas[0].state
        left.join(replicas[1].state)
        left.join(replicas[2].state)
        // a ⊔ (b ⊔ c)
        var bc = replicas[1].state
        bc.join(replicas[2].state)
        var right = replicas[0].state
        right.join(bc)

        #expect(left == right, "join not associative (seed \(seed))")
    }
}
