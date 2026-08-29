import FlightPubSub
import struct Foundation.UUID
import Synchronization

/// An in-memory "wire" connecting any number of `DistributedPubSubAdapter`s
/// in one process — multi-node topologies without a network. Each
/// `makeAdapter()` is one node's uplink: its `broadcast` is delivered into
/// every other node's `incoming()` stream.
///
/// `echoesToOrigin` controls whether a node's own broadcasts are also
/// delivered back to it, simulating transports that do (Redis pub/sub echoes
/// to the publishing connection's subscribers). `ClusteredPubSub`'s origin
/// filtering must make the two modes indistinguishable to subscribers —
/// which is exactly what tests use this flag to prove.
public final class InMemoryCluster: Sendable {

    private let echoesToOrigin: Bool
    private let nodes = Mutex<[UUID: AsyncStream<Message>.Continuation]>([:])

    public init(echoesToOrigin: Bool = false) {
        self.echoesToOrigin = echoesToOrigin
    }

    /// Join the cluster; the returned adapter is one node's transport.
    public func makeAdapter() -> InMemoryClusterAdapter {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(
            of: Message.self,
            bufferingPolicy: .unbounded
        )
        nodes.withLock { $0[id] = continuation }
        return InMemoryClusterAdapter(id: id, cluster: self, stream: stream)
    }

    /// Finish every node's incoming stream — simulates the whole cluster
    /// going away, ending each node's relay loop.
    public func disconnectAll() {
        let continuations = nodes.withLock { state in
            let values = Array(state.values)
            state.removeAll()
            return values
        }
        for continuation in continuations {
            continuation.finish()
        }
    }

    fileprivate func deliver(from origin: UUID, _ message: Message) {
        let continuations = nodes.withLock { state in
            state.compactMap { id, continuation in
                (echoesToOrigin || id != origin) ? continuation : nil
            }
        }
        for continuation in continuations {
            continuation.yield(message)
        }
    }

    fileprivate func leave(_ id: UUID) {
        let continuation = nodes.withLock { $0.removeValue(forKey: id) }
        continuation?.finish()
    }
}

/// One node's transport on an `InMemoryCluster`.
public struct InMemoryClusterAdapter: DistributedPubSubAdapter {
    fileprivate let id: UUID
    fileprivate let cluster: InMemoryCluster
    fileprivate let stream: AsyncStream<Message>

    public func broadcast(_ message: Message) async throws {
        cluster.deliver(from: id, message)
    }

    public func incoming() -> AsyncStream<Message> {
        stream
    }

    /// Leave the cluster, finishing this node's incoming stream.
    public func disconnect() {
        cluster.leave(id)
    }
}
