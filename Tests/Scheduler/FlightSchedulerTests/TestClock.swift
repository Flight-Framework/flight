import Foundation
import Synchronization

@testable import FlightScheduler

/// A clock a test drives.
///
/// `sleep(until:)` jumps straight to the instant instead of waiting, so a
/// test can run a year of firings in microseconds. Every scheduler test here
/// uses it; none of them sleep, which is the difference between a suite that
/// is trustworthy and one that goes red on a loaded CI machine.
final class TestClock: SchedulerClock, @unchecked Sendable {
    private let state = Mutex<Date>(Date(timeIntervalSince1970: 0))
    /// Every instant slept to, in order — the firing sequence, assertable.
    let sleeps = Mutex<[Date]>([])

    init(now: Date) { state.withLock { $0 = now } }

    var now: Date { state.withLock { $0 } }

    func advance(to instant: Date) { state.withLock { $0 = max($0, instant) } }

    func sleep(until instant: Date) async throws {
        try Task.checkCancellation()
        sleeps.withLock { $0.append(instant) }
        advance(to: instant)
        // Yield so a cancelling task gets a turn; without this a loop that
        // never suspends would starve cancellation and hang the test.
        await Task.yield()
        try Task.checkCancellation()
    }
}

/// A coordinator that answers as the test tells it to, and records what was
/// asked.
final class StubCoordinator: JobCoordinator, @unchecked Sendable {
    private let answer: Mutex<Bool>
    private let failure: Mutex<(any Error)?>
    let claims = Mutex<[String]>([])
    let releases = Mutex<[String]>([])

    init(claims answer: Bool = true, failsWith error: (any Error)? = nil) {
        self.answer = Mutex(answer)
        self.failure = Mutex(error)
    }

    func claim(job: String, scheduledFor: Date) async throws -> Bool {
        if let error = failure.withLock({ $0 }) { throw error }
        claims.withLock { $0.append(job) }
        return answer.withLock { $0 }
    }

    func release(job: String, scheduledFor: Date) async {
        releases.withLock { $0.append(job) }
    }

    var describedKind: String { "stub" }
}

struct StubError: Error, Equatable { let message: String }
