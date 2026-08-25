import Foundation

/// Decides which process runs a ``JobScope/once`` job for a given firing.
///
/// With one server this is trivial and ``LocalJobCoordinator`` answers yes to
/// everything. With several it is the whole problem: a nightly billing run
/// that fires on three servers bills three times, and nothing about the job
/// itself can prevent that.
///
/// The contract is deliberately small enough to implement against anything
/// that offers an atomic conditional write — a Postgres advisory lock, a
/// Valkey `SET NX`, a lease row, a consensus store.
///
/// ## What an implementation must guarantee
///
/// For a given `(job, scheduledFor)` pair, ``claim(job:scheduledFor:)`` must
/// return `true` in **at most one** process. Returning `true` in none is
/// survivable — that firing is skipped and logged. Returning `true` in two is
/// the bug this exists to prevent, so an implementation in doubt must refuse.
///
/// `scheduledFor` is part of the key rather than a wall-clock "now" so two
/// servers whose clocks differ by a second still agree about *which firing*
/// they are contending for.
public protocol JobCoordinator: Sendable {
    /// Whether this process should run `job` for the firing at `scheduledFor`.
    func claim(job: String, scheduledFor: Date) async throws -> Bool

    /// Called after a claimed run finishes, successfully or not.
    ///
    /// Lock-based implementations release here. Lease-based ones may do
    /// nothing and let the lease expire — which is why this cannot fail: a
    /// release that throws would have nowhere useful to report to.
    func release(job: String, scheduledFor: Date) async

    /// Shown in the startup log line, so an operator can tell at a glance
    /// which coordination is actually in force.
    var describedKind: String { get }
}

/// The single-process coordinator: everything is claimable, because there is
/// nobody to contend with.
///
/// This is not a stub. On one server it is the *correct* implementation, and
/// the overwhelming majority of deployments have one server. What it cannot
/// do is span processes — which is why the scheduler refuses to pretend, and
/// says so at startup when it finds `.once` jobs and no distributed
/// coordinator.
public struct LocalJobCoordinator: JobCoordinator {
    public init() {}
    public func claim(job: String, scheduledFor: Date) async throws -> Bool { true }
    public func release(job: String, scheduledFor: Date) async {}
    public var describedKind: String { "single-process" }
}

/// How the scheduler is coordinating, resolved from what is registered and
/// logged loudly at startup.
///
/// The same discipline as `PresenceMode`: the mode is derived rather than
/// configured, and it is reported at boot because the failure it guards
/// against is silent. A deployment that believes `.once` means once and is
/// actually running every job on every server finds out from its data, which
/// is the worst possible place.
public enum SchedulerMode: Sendable, Equatable {
    /// No distributed coordinator registered. Correct on one server; on more
    /// than one, every `.once` job runs on every server.
    case singleProcess
    /// A ``JobCoordinator`` is registered, named here for the log line.
    case coordinated(String)

    public var description: String {
        switch self {
        case .singleProcess: return "single-process"
        case .coordinated(let kind): return kind
        }
    }
}
