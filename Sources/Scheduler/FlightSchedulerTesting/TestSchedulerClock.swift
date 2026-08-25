import FlightScheduler
import Foundation
import Synchronization

/// A clock a test drives, so scheduler tests do not sleep.
///
/// `sleep(until:)` jumps straight to the instant rather than waiting, which
/// turns "does this daily job fire on the day the clocks go back" from an
/// untestable question into a microsecond one:
///
/// ```swift
/// let clock = TestSchedulerClock(now: someDate)
/// // drive a scheduler with it, then:
/// #expect(clock.sleeps.count == 3)
/// ```
///
/// A scheduler tested against the real clock is a slow suite and a flaky
/// one — the two properties worth having least, and the reason
/// ``FlightScheduler/SchedulerClock`` is a seam at all.
public final class TestSchedulerClock: SchedulerClock, Sendable {
    private let current: Mutex<Date>
    private let recorded: Mutex<[Date]>

    public init(now: Date) {
        self.current = Mutex(now)
        self.recorded = Mutex([])
    }

    public var now: Date { current.withLock { $0 } }

    /// Every instant slept to, in order — the firing sequence, assertable.
    public var sleeps: [Date] { recorded.withLock { $0 } }

    /// Moves time forward. Never backwards: a clock that can go back would
    /// let a test assert a sequence the real scheduler can never produce.
    public func advance(to instant: Date) {
        current.withLock { $0 = max($0, instant) }
    }

    public func advance(by duration: Duration) {
        current.withLock { $0 = $0.addingTimeInterval(Double(duration.components.seconds)) }
    }

    public func sleep(until instant: Date) async throws {
        try Task.checkCancellation()
        recorded.withLock { $0.append(instant) }
        advance(to: instant)
        // Yields so a cancelling task gets a turn. Without this, a loop that
        // never actually suspends starves cancellation and hangs the test —
        // which is a worse failure than the one being tested for.
        await Task.yield()
        try Task.checkCancellation()
    }
}

/// A coordinator with a fixed answer, for testing what a job does when it
/// wins or loses a claim.
///
/// ``StubJobCoordinator/refusing`` is the interesting one: it exercises the
/// path where another process took the firing, which is otherwise only
/// reachable by running two servers.
public final class StubJobCoordinator: JobCoordinator, Sendable {
    private let answer: Bool
    private let error: (any Error)?
    private let claimed = Mutex<[String]>([])
    private let released = Mutex<[String]>([])

    /// Claims everything — what a single process sees.
    public static var claiming: StubJobCoordinator { StubJobCoordinator(claims: true) }
    /// Claims nothing — what a process that lost every race sees.
    public static var refusing: StubJobCoordinator { StubJobCoordinator(claims: false) }
    /// Fails every claim, for testing that an unreachable coordinator does
    /// not become permission to run.
    public static func failing(_ error: any Error) -> StubJobCoordinator {
        StubJobCoordinator(claims: false, failsWith: error)
    }

    public init(claims: Bool = true, failsWith error: (any Error)? = nil) {
        self.answer = claims
        self.error = error
    }

    public var claimedJobs: [String] { claimed.withLock { $0 } }
    public var releasedJobs: [String] { released.withLock { $0 } }

    public func claim(job: String, scheduledFor: Date) async throws -> Bool {
        if let error { throw error }
        claimed.withLock { $0.append(job) }
        return answer
    }

    public func release(job: String, scheduledFor: Date) async {
        released.withLock { $0.append(job) }
    }

    public var describedKind: String { "stub" }
}
