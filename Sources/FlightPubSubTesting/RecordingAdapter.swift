import FlightPubSub
import Synchronization

/// A `DistributedPubSubAdapter` for unit-testing clustered code paths in
/// isolation: records every `broadcast`, lets the test inject `incoming()`
/// messages by hand, and can be armed to fail broadcasts.
public final class RecordingAdapter: DistributedPubSubAdapter, Sendable {

    private struct State {
        var broadcasts: [Message] = []
        var broadcastError: (any Error)?
    }

    private let state = Mutex(State())
    private let incomingStream: AsyncStream<Message>
    private let incomingContinuation: AsyncStream<Message>.Continuation

    public init() {
        (incomingStream, incomingContinuation) = AsyncStream.makeStream(
            of: Message.self,
            bufferingPolicy: .unbounded
        )
    }

    // MARK: - DistributedPubSubAdapter

    public func broadcast(_ message: Message) async throws {
        let error = state.withLock { state -> (any Error)? in
            if let error = state.broadcastError { return error }
            state.broadcasts.append(message)
            return nil
        }
        if let error { throw error }
    }

    public func incoming() -> AsyncStream<Message> {
        incomingStream
    }

    // MARK: - Test controls

    /// Everything broadcast so far, in order.
    public var broadcasts: [Message] {
        state.withLock { $0.broadcasts }
    }

    /// While set, `broadcast` throws this instead of recording.
    public func setBroadcastError(_ error: (any Error)?) {
        state.withLock { $0.broadcastError = error }
    }

    /// Deliver a message as if it arrived from another node.
    public func inject(_ message: Message) {
        incomingContinuation.yield(message)
    }

    /// End the incoming stream, as a permanently-lost connection would.
    public func finishIncoming() {
        incomingContinuation.finish()
    }
}
