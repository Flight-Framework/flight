/// The seam `@Transactional`'s expansion targets (§5.2).
///
/// Core owns only the *shape* of transaction coordination — begin, commit,
/// rollback around a wrapped body — never a datasource. Flight Data supplies
/// a real coordinator and binds it (task-locally, so nested/parallel
/// pipelines can carry different coordinators); Core ships a no-op default so
/// `@Transactional` code is runnable and testable without Flight Data.
///
/// The coordinator's methods are synchronous on purpose: §5.4's fixture list
/// requires `@Transactional` to work on *synchronous* throwing methods, and a
/// sync method body cannot await. A coordinator that fronts async I/O bridges
/// internally (connection checkout at begin is Flight Data's concern). If
/// that bridge proves ugly in practice, the deliberate fix is a second
/// async-native coordinator protocol — recorded as an open question in
/// SPIKE-FINDINGS.md, not silently designed around here.
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

/// Async-native coordination (delta 14) — the resolution of SPIKE-FINDINGS'
/// "sync vs async coordinator" open question, chosen deliberately once the
/// sync bridge had a real cost to point at (Flight Data Postgres delta P2:
/// every BEGIN/COMMIT/ROLLBACK blocked a thread on an `EventLoopFuture`).
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
    @TaskLocal public static var coordinator: any FlightTransactionCoordinator = NoopTransactionCoordinator()

    /// The async-native coordinator, when the bound datasource offers one
    /// (delta 14). `nil` by default — an async `@Transactional` method then
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
        if let asyncCoordinator {
            await asyncCoordinator.rollback(token)
        } else {
            coordinator.rollback(token)
        }
    }
}

/// Default coordinator: allocates tokens, does nothing else. Also handy in
/// tests as a base for recording coordinators.
public struct NoopTransactionCoordinator: FlightTransactionCoordinator {
    public init() {}
    public func begin() throws -> FlightTransactionToken { FlightTransactionToken(id: 0) }
    public func commit(_ token: FlightTransactionToken) throws {}
    public func rollback(_ token: FlightTransactionToken) {}
}
