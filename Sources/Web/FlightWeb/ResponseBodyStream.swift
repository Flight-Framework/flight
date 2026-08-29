import Foundation
import Synchronization

/// The write surface handed to a streaming response producer.
///
/// ``write(_:)`` **suspends until the chunk has been taken**, and that is the
/// whole reason this type exists. The producer used to be handed an
/// `AsyncStream<Data>.Continuation` created with the default `.unbounded`
/// buffering policy, and `yield` never suspends — so a producer faster than
/// its client grew the buffer without limit. An SSE endpoint pushing updates
/// to a phone on a train was a memory leak with a pleasant API, and the
/// `send` that promised to report a disconnect could only do so *after*
/// termination had propagated, by which time everything written in the
/// meantime was already held in memory.
///
/// Request-body backpressure was fixed in 0.8.0. This is the same fix
/// pointing the other way.
public struct ResponseBodyWriter: Sendable {
    let handoff: ResponseBodyHandoff

    /// Writes one chunk, suspending until the transport has taken it.
    ///
    /// Returns `false` once the client is gone — at which point the producer
    /// has nothing left to write for and should return. A discarded result is
    /// legitimate for a producer that will notice through cancellation
    /// instead.
    @discardableResult
    public func write(_ chunk: Data) async -> Bool {
        await handoff.send(chunk)
    }

    /// Ends the stream early. Returning from the producer closure does this
    /// too, so this is for the producer that wants to stop mid-loop.
    public func finish() {
        handoff.finish()
    }
}

/// A one-chunk rendezvous between a response-body producer and whatever is
/// writing bytes to the client.
///
/// `Mutex` rather than an actor for the reason `LocalPubSub` gives for the
/// same choice: the critical sections are a handful of field assignments, and
/// an actor would put a hop on every chunk of every streamed response.
/// Continuations are captured under the lock and resumed after leaving it,
/// which is what keeps a resume from re-entering it.
final class ResponseBodyHandoff: Sendable {

    private struct State {
        /// A chunk written but not yet taken. Non-nil only while the producer
        /// is parked, which is what makes "at most one chunk in flight" true
        /// rather than aspirational.
        var pending: Data?
        var isFinished = false
        var consumer: CheckedContinuation<Data?, Never>?
        var producer: CheckedContinuation<Bool, Never>?
    }

    private let state = Mutex(State())

    /// Producer side. Suspends until the chunk is taken; `false` means the
    /// consumer is gone.
    func send(_ chunk: Data) async -> Bool {
        enum Outcome { case gone, taken, parked }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let (outcome, waitingConsumer) = state.withLock {
                s -> (Outcome, CheckedContinuation<Data?, Never>?) in
                if s.isFinished { return (.gone, nil) }
                if let consumer = s.consumer {
                    s.consumer = nil
                    return (.taken, consumer)
                }
                s.pending = chunk
                s.producer = continuation
                return (.parked, nil)
            }
            switch outcome {
            case .gone:
                continuation.resume(returning: false)
            case .taken:
                waitingConsumer?.resume(returning: chunk)
                continuation.resume(returning: true)
            case .parked:
                break  // `next()` or `finish()` resumes it
            }
        }
    }

    /// Consumer side: the next chunk, or nil once the producer is done.
    func next() async -> Data? {
        enum Outcome { case value(Data), finished, parked }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            let (outcome, waitingProducer) = state.withLock {
                s -> (Outcome, CheckedContinuation<Bool, Never>?) in
                if let chunk = s.pending {
                    s.pending = nil
                    let producer = s.producer
                    s.producer = nil
                    return (.value(chunk), producer)
                }
                if s.isFinished { return (.finished, nil) }
                s.consumer = continuation
                return (.parked, nil)
            }
            waitingProducer?.resume(returning: true)
            switch outcome {
            case .value(let chunk): continuation.resume(returning: chunk)
            case .finished: continuation.resume(returning: nil)
            case .parked: break  // `send()` or `finish()` resumes it
            }
        }
    }

    /// Ends the exchange from either side. Idempotent: a producer that
    /// finishes and then returns runs this twice, and a client that
    /// disconnects mid-write runs it while the producer is parked.
    func finish() {
        let (waitingConsumer, waitingProducer) = state.withLock {
            s -> (CheckedContinuation<Data?, Never>?, CheckedContinuation<Bool, Never>?) in
            s.isFinished = true
            s.pending = nil
            let consumer = s.consumer
            let producer = s.producer
            s.consumer = nil
            s.producer = nil
            return (consumer, producer)
        }
        waitingConsumer?.resume(returning: nil)
        waitingProducer?.resume(returning: false)
    }
}

/// Owns the producer task for one streamed response, and stops it when the
/// stream itself goes away.
///
/// Held only by the stream's unfolding closure, never by the producer task —
/// the task holds the handoff instead. A cycle here would keep a parked
/// producer alive forever on a dropped response.
final class ResponseBodyProducer: Sendable {
    private let handoff: ResponseBodyHandoff
    private let task: Mutex<Task<Void, Never>?> = Mutex(nil)
    private let start: @Sendable (ResponseBodyHandoff) -> Task<Void, Never>

    init(handoff: ResponseBodyHandoff, start: @escaping @Sendable (ResponseBodyHandoff) -> Task<Void, Never>) {
        self.handoff = handoff
        self.start = start
    }

    /// Starts the producer the first time the consumer asks for a chunk.
    ///
    /// Lazily, because starting it at response construction — which is what
    /// used to happen — meant it ran before the transport had so much as
    /// looked at the response, so everything it produced up to the first read
    /// was buffered by definition.
    func ensureStarted() {
        task.withLock { existing in
            if existing == nil { existing = start(handoff) }
        }
    }

    func stop() {
        handoff.finish()
        task.withLock { $0?.cancel() }
    }

    deinit { stop() }
}
