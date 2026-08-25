import Logging
import Synchronization

/// The seam `@Transactional`'s expansion targets.
///
/// Core owns only the *shape* of transaction coordination — begin, commit,
/// rollback around a wrapped body — never a datasource. Flight Data supplies
/// a real coordinator and binds it (task-locally, so nested/parallel
/// pipelines can carry different coordinators); Core ships a no-op default so
/// `@Transactional` code is runnable and testable without Flight Data.
///
/// The coordinator's methods are synchronous on purpose: 's fixture list
/// requires `@Transactional` to work on *synchronous* throwing methods, and a
/// sync method body cannot await. A coordinator that fronts async I/O bridges
/// internally (connection checkout at begin is Flight Data's concern). If
/// that bridge proves ugly in practice, the deliberate fix is a second
/// async-native coordinator protocol — recorded as an open question in
/// the design notes, not silently designed around here.
public protocol FlightTransactionCoordinator: Sendable {
    func begin() throws -> FlightTransactionToken
    func commit(_ token: FlightTransactionToken) throws
    /// Non-throwing: rollback runs on the error path, where a second thrown
    /// error would mask the original. Coordinators log rollback failures.
    func rollback(_ token: FlightTransactionToken)
}

public struct FlightTransactionToken: Sendable, Hashable {
    public let id: UInt64
    public init(id: UInt64) { self.id = id }
}

/// Async-native transaction coordination.
///
/// The synchronous coordinator came first, and it had a real cost: a
/// database adapter's `BEGIN`/`COMMIT`/`ROLLBACK` each blocked a thread on a
/// future. This is the async-native path adapters should implement.
///
/// `@Transactional` on an *async* method prefers this coordinator when one
/// is bound, so control statements are awaited instead of blocked on; on a
/// *sync* method the sync coordinator remains the only option a non-async
/// body can use. Coordinators fronting async I/O implement both: the sync
/// conformance keeps `@Transactional` legal on sync methods (bridging
/// internally), the async conformance serves everything else natively.
public protocol FlightAsyncTransactionCoordinator: Sendable {
    func begin() async throws -> FlightTransactionToken
    func commit(_ token: FlightTransactionToken) async throws
    /// Non-throwing for the same reason as the sync protocol: rollback runs
    /// on the error path, where a second thrown error would mask the first.
    func rollback(_ token: FlightTransactionToken) async
}

public enum FlightTransactions {
    /// Task-local so coordinators compose with structured concurrency; the
    /// default makes @Transactional a no-op wrapper outside Flight Data.
    @TaskLocal public static var coordinator: any FlightTransactionCoordinator =
        NoopTransactionCoordinator()

    /// The async-native coordinator, when the bound datasource offers one
    ///. `nil` by default — an async `@Transactional` method then
    /// falls back to `coordinator`, so sync-only coordinators (and Core's
    /// no-op default) keep working unchanged.
    @TaskLocal public static var asyncCoordinator: (any FlightAsyncTransactionCoordinator)?

    // MARK: - Selection used by @Transactional's async expansion

    /// These helpers exist so the macro's async expansion stays flat and
    /// inspectable (one call, not an inlined coordinator-selection branch).
    /// Sync expansions never call them — a sync body cannot await.

    public static func beginPreferringAsync() async throws -> FlightTransactionToken {
        if let asyncCoordinator {
            return try await asyncCoordinator.begin()
        }
        return try coordinator.begin()
    }

    public static func commitPreferringAsync(_ token: FlightTransactionToken) async throws {
        if let asyncCoordinator {
            try await asyncCoordinator.commit(token)
        } else {
            try coordinator.commit(token)
        }
    }

    public static func rollbackPreferringAsync(_ token: FlightTransactionToken) async {
        guard let asyncCoordinator else {
            coordinator.rollback(token)
            return
        }
        // A transaction body that threw CancellationError leaves this task
        // already cancelled, and a coordinator whose rollback performs real
        // I/O would have that I/O fail immediately — leaving the transaction
        // open, silently, because rollback is deliberately non-throwing.
        // Run it in a detached task so the cleanup gets an uncancelled
        // context, and wait for it so the guarantee still holds on return.
        await Task.detached(priority: Task.currentPriority) {
            await asyncCoordinator.rollback(token)
        }.value
    }
}

/// Default coordinator: allocates tokens, does nothing else. Also handy in
/// tests as a base for recording coordinators.
///
/// Reaching this coordinator from a real `@Transactional` method is almost
/// always a wiring mistake, and it is a silent one: the method runs, every
/// write lands, every test passes, and the first time a body throws halfway
/// through, the writes before the throw stay. So the first time it is asked
/// to begin a transaction, it says so.
///
/// Once per process, at warning level, rather than a thrown error: this is
/// also the honest default for an application with no data layer at all, and
/// for the coordinator-recording fakes a test suite builds on it. Loud
/// enough to be found, not so loud it cannot be lived with.
public struct NoopTransactionCoordinator: FlightTransactionCoordinator {
    private static let warnings = Mutex(0)

    /// The text, held as a constant so the test asserting it is actionable
    /// reads the same string the log does.
    static let warningMessage = """
        @Transactional ran with no transaction coordinator bound, so it did nothing: \
        the method's writes are not atomic and a thrown error will not roll them back. \
        Bind one around the unit of work — withPostgresScope for a job, CLI command or \
        test, or withPostgresTransactions(in:) for a scope you already have, such as a \
        web request's. This warning is logged once per process.
        """

    /// How many times the warning has actually been emitted. The
    /// once-per-process behaviour is the contract; this is how a test sees it.
    static var warningCountForTesting: Int { warnings.withLock { $0 } }

    public init() {}

    public func begin() throws -> FlightTransactionToken {
        Self.warnOnce()
        return FlightTransactionToken(id: 0)
    }

    public func commit(_ token: FlightTransactionToken) throws {}
    public func rollback(_ token: FlightTransactionToken) {}

    /// Lets a test observe the first warning more than once. The
    /// once-per-process behaviour is the contract; this only exists so the
    /// test asserting it can run twice in one process.
    static func resetWarningForTesting() {
        warnings.withLock { $0 = 0 }
    }

    /// Says what happened, and both ways to fix it, once.
    static func warnOnce() {
        let first = warnings.withLock { count -> Bool in
            guard count == 0 else { return false }
            count = 1
            return true
        }
        guard first else { return }
        Logger(label: "flight.transactions").warning("\(warningMessage)")
    }
}
