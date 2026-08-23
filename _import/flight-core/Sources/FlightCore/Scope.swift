import Synchronization

/// A bounded lifetime that some number of components live and die with.
/// Core has no opinion about what creates or ends one — request, job, CLI
/// invocation are all Web/consumer-layer *interpretations* of this primitive.
public final class Scope: Sendable {
    /// Region-isolation shim: `Mutex.withLock` requires `sending` in and out,
    /// and a raw `Any` merges the caller's task region into the protected map.
    /// The box is `@unchecked Sendable` on the same grounds as
    /// `FrozenStorage.singletons` — component instances are published through
    /// container/scope storage and read-only thereafter.
    private struct StoredInstance: @unchecked Sendable {
        let value: Any
    }

    // "Internally synchronized; short-lived, low contention expected".
    // A Mutex (not an actor) because instance lookup must stay synchronous —
    // scoped resolution happens inside synchronous factory bodies.
    private let storage = Mutex<[ComponentKey: StoredInstance]?>([:])

    public init() {}

    /// Get-or-create with first-writer-wins semantics. `create` deliberately
    /// runs *outside* the lock: factories may resolve nested scoped
    /// dependencies through this same Scope, and Mutex is non-reentrant —
    /// holding it across `create` would deadlock on exactly the nested case
    /// scopes exist for. The cost is a rare duplicate construction under
    /// concurrent first-touch of the same component, discarded in favor of the
    /// first insert. For request/job-shaped scopes that race is effectively
    /// unreachable; if profiling ever says otherwise, per-key once-flags are
    /// the upgrade path (measure first).
    internal func instance(for key: ComponentKey, create: () throws -> Any) throws -> Any {
        let existing = try storage.withLock { map -> StoredInstance? in
            guard let map else { throw ScopeError.closed }
            return map[key]
        }
        if let existing { return existing.value }

        let fresh = StoredInstance(value: try create())

        let winner = try storage.withLock { map -> StoredInstance in
            guard map != nil else { throw ScopeError.closed }
            if let winner = map![key] { return winner }
            map![key] = fresh
            return fresh
        }
        return winner.value
    }

    /// Ends the scope: instances become eligible for cleanup. Called by
    /// `withScope`'s defer; safe to call more than once.
    internal func close() {
        storage.withLock { $0 = nil }
    }
}

public enum ScopeError: Error, Sendable, CustomStringConvertible {
    case closed
    public var description: String {
        "Scope used after its withScope body returned — a Scope's lifetime is exactly its body."
    }
}

extension Scope {
    /// The scope the current resolution is running against, if any.
    ///
    /// Component factories receive only the `Container` — deliberately, so that a
    /// component's dependencies never outlive it by accident. But that left scoped
    /// components unable to *depend on each other*: a scoped repository's factory
    /// had no path to the scope's connection. Flight Data — the second Scope
    /// consumer — is what surfaced the gap.
    ///
    /// `Container.resolve(_:qualifier:in:)` binds this task-local for the
    /// duration of the resolution, so factories running underneath it can
    /// resolve further scoped components against the same scope via
    /// `resolveInActiveScope`. Bound synchronously; nil outside a scoped
    /// resolution (including during `freeze()`'s eager singleton
    /// construction, where depending on a scope must fail loudly).
    @TaskLocal public static var active: Scope?
}

extension Container {
    /// Opens a scope, runs `body`, and releases the scope's instances when
    /// `body` returns. Core has no idea what `body` represents.
    public func withScope<T>(_ body: (Scope) throws -> T) rethrows -> T {
        let scope = Scope()
        defer { scope.close() }
        return try body(scope)
    }

    public func withScope<T>(_ body: (Scope) async throws -> T) async rethrows -> T {
        let scope = Scope()
        defer { scope.close() }
        return try await body(scope)
    }

    /// Resolution against the ambient scope — the factory-side
    /// counterpart of `resolve(_:qualifier:in:)`.
    ///
    /// For use inside component factories, which receive only the `Container`: a
    /// scoped (or transient) component that depends on another scoped component resolves
    /// it through this method, and both land in the scope the outer resolution
    /// was called with. Outside a scoped resolution there is no ambient scope
    /// and this throws `ResolutionError.noActiveScope` — which is exactly what
    /// makes a singleton depending on a scoped component (a captive dependency)
    /// fail loudly at `freeze()` instead of silently pinning one connection
    /// for the app's lifetime.
    ///
    /// Now plain `resolve` performs the same fallback for
    /// `.scoped` registrations (throwing `scopeRequired` with no scope
    /// bound), so `@Autowired` covers this shape too. This method remains as
    /// the *explicit* spelling: it declares "I expect an ambient scope", and
    /// its distinct `noActiveScope` error names the captive-dependency case
    /// precisely.
    public func resolveInActiveScope<T: Sendable>(_ type: T.Type = T.self, qualifier: String? = nil)
        throws -> T
    {
        guard let scope = Scope.active else {
            throw ResolutionError.noActiveScope(
                ComponentKey(type, qualifier: qualifier).description)
        }
        return try resolve(type, qualifier: qualifier, in: scope)
    }
}
