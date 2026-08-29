import Synchronization

/// A result that exactly one of several racers gets to set, first writer
/// winning — the shape of "do this, but give up after a while".
///
/// The reason this is a type rather than a `withThrowingTaskGroup` at each
/// call site: **a task group awaits all of its children at scope exit.** So
/// `cancelAll()` after a timeout fires only helps if the losing child
/// responds to cancellation, and a child parked in non-cancellable work —
/// blocking I/O bridged to async, a continuation nobody resumes — hangs the
/// whole group *despite* the timeout. That is not a hypothetical: it is how
/// `ClusteredPubSub`'s `broadcastTimeout` failed to bound `publish` for two
/// releases, against a `DistributedPubSubAdapter` contract that never
/// required cancellation-responsiveness in the first place.
///
/// Racers here are unstructured, so the winner returns immediately and a
/// wedged loser is cancelled and left to finish or not. Use this wherever the
/// racer is somebody else's code behind a protocol or a closure — which is
/// to say, wherever a timeout is actually load-bearing.
public final class FirstAnswer: Sendable {

    private struct State {
        var isAnswered = false
        var waiting: CheckedContinuation<Void, any Error>?
        var pending: Result<Void, any Error>?
    }

    private let state = Mutex(State())

    public init() {}

    /// Suspends until some racer answers. Rethrows a failing answer.
    public func wait() async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            let ready = state.withLock { s -> Result<Void, any Error>? in
                if let pending = s.pending { return pending }
                s.waiting = continuation
                return nil
            }
            if let ready { continuation.resume(with: ready) }
        }
    }

    /// Records an answer. The first call wins; later ones are dropped, which
    /// is what lets every racer report unconditionally.
    ///
    /// The continuation is captured under the lock and resumed after it is
    /// released, so a resume cannot re-enter it.
    public func answer(_ result: Result<Void, any Error>) {
        let waiting = state.withLock { s -> CheckedContinuation<Void, any Error>? in
            guard !s.isAnswered else { return nil }
            s.isAnswered = true
            if let waiting = s.waiting {
                s.waiting = nil
                return waiting
            }
            s.pending = result
            return nil
        }
        waiting?.resume(with: result)
    }
}

/// Runs `work`, giving up after `timeout` and throwing `timedOut`.
///
/// Returns as soon as either finishes. A `work` that ignores cancellation
/// keeps running — there is no way to stop code that will not stop — but it
/// no longer holds up the caller, which is the property a timeout is for.
public func withFlightTimeout(
    _ timeout: Duration?,
    throwing timedOut: @autoclosure @Sendable () -> any Error,
    _ work: @escaping @Sendable () async throws -> Void
) async throws {
    guard let timeout else {
        try await work()
        return
    }
    let answer = FirstAnswer()
    let worker = Task {
        do {
            try await work()
            answer.answer(.success(()))
        } catch {
            answer.answer(.failure(error))
        }
    }
    let error = timedOut()
    let timer = Task {
        do { try await Task.sleep(for: timeout) } catch { return }
        answer.answer(.failure(error))
        worker.cancel()
    }
    defer { timer.cancel() }
    try await answer.wait()
}
