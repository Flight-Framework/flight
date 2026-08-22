import Synchronization

/// The Flight DI container (§2).
///
/// ## The two-phase model, as implemented
///
/// - **Registration phase** — from `init()` until `freeze()`. Strictly
///   single-threaded *by contract* (bootstrap runs `configure(_:)` serially,
///   §7 step 6). Registration state is therefore held in plain vars guarded
///   by preconditions, not locks — a lock here would launder a contract
///   violation into silent misbehavior instead of a loud trap.
/// - **Resolution phase** — from the moment `freeze()` returns. `frozenStorage`
///   is written exactly once, and every concurrent reader lives in a task
///   created *after* `freeze()` returns (bootstrap hands services to the
///   ServiceGroup only after step 7). Task creation establishes the
///   happens-before edge, so the publication is ordered without any fence,
///   lock, or atomic — this is the §8 "post-freeze case likely needs no
///   synchronization primitive whatsoever" claim, made concrete. The
///   `nonisolated(unsafe)` below is the single, documented place where that
///   argument is load-bearing.
///
/// `@unchecked Sendable` is justified by exactly the reasoning above; if the
/// two-phase contract ever changes, this annotation is the first thing to
/// re-audit.
public final class Container: @unchecked Sendable {

    // MARK: - Registration-phase state (single-threaded by contract)

    private enum Phase { case registering, freezing, frozen }
    private var phase: Phase = .registering
    private var registrations: [ComponentKey: Registration] = [:]
    private var order: [ComponentKey] = []
    private var singletonsUnderConstruction: [ComponentKey: Any] = [:]

    /// Stamped by bootstrap around each module's `configure` call so that
    /// `ComponentDescriptor.sourceModule` requires nothing from module authors.
    internal var currentSourceModule: String = "<direct>"

    // MARK: - Post-freeze state (write-once, then read-only)

    nonisolated(unsafe) private var frozenStorage: FrozenStorage?

    // MARK: - Module health (§6.1) — mutated during the service-run phase,
    // so unlike component storage this genuinely needs synchronization.

    private struct HealthState {
        var order: [String] = []
        var map: [String: ModuleHealth] = [:]
    }
    private let healthState = Mutex(HealthState())

    public init() {}

    // MARK: - Registration

    /// Only callable during the registration phase. Traps if called after
    /// `freeze()` — programmer error, not a runtime condition (§2.1).
    public func register<T>(
        _ type: T.Type,
        qualifier: String? = nil,
        scope: Lifetime,
        stereotype: Stereotype = .component,
        factory: @escaping @Sendable (Container) throws -> T
    ) {
        precondition(
            phase == .registering,
            "Container.register called after freeze(). Registration is only legal during the bootstrap registration phase (§2.1)."
        )
        let key = ComponentKey(type, qualifier: qualifier)
        precondition(
            registrations[key] == nil,
            "Duplicate registration for \(key). Use a qualifier to register multiple components of one type."
        )
        let descriptor = ComponentDescriptor(
            typeName: key.typeName,
            scope: scope,
            sourceModule: currentSourceModule,
            qualifier: qualifier,
            stereotype: stereotype
        )
        registrations[key] = Registration(key: key, scope: scope, descriptor: descriptor) { c in
            try factory(c)
        }
        order.append(key)
    }

    /// Called once by bootstrap after all modules have configured (§7 step 7).
    /// Irreversible for the lifetime of the process.
    ///
    /// Deviation from the spec doc's `freeze()` signature, deliberately:
    /// singletons are constructed eagerly *here* (that eagerness is what makes
    /// post-freeze resolution a pure read), and a factory failure at startup
    /// must surface as an error to the already-throwing bootstrap sequence,
    /// not a trap. Recorded in SPIKE-FINDINGS.md → Design deltas.
    public func freeze() throws {
        precondition(phase == .registering, "freeze() called more than once.")
        phase = .freezing
        for key in order where registrations[key]?.scope == .singleton {
            _ = try resolveAny(key: key)
        }
        frozenStorage = FrozenStorage(
            registrations: registrations,
            order: order,
            singletons: singletonsUnderConstruction
        )
        singletonsUnderConstruction = [:]
        phase = .frozen
    }

    public var isFrozen: Bool { frozenStorage != nil }

    // MARK: - Resolution

    /// Safe to call concurrently post-freeze; no isolation required (§2.1).
    /// Throws `ResolutionError.notRegistered` as the fallback for genuinely
    /// dynamic resolution (§5.3) — the macro-generated path is validated at
    /// compile time and should never hit it.
    public func resolve<T>(_ type: T.Type = T.self, qualifier: String? = nil) throws -> T {
        let key = ComponentKey(type, qualifier: qualifier)
        let value = try resolveAny(key: key)
        guard let typed = value as? T else {
            throw ResolutionError.typeMismatch(
                requested: key.typeName,
                produced: String(reflecting: Swift.type(of: value))
            )
        }
        return typed
    }

    /// Scoped resolution (§3). `.singleton`/`.transient` components resolved through
    /// this overload behave exactly as plain `resolve` — a component's scope is a
    /// property of its registration, not of the call site.
    ///
    /// The whole resolution runs with `Scope.active` bound to `scope`
    /// (delta 11), and since delta 12 plain `resolve` consults that binding
    /// for `.scoped` registrations — so this overload is now exactly "bind
    /// the scope, then resolve". Factories underneath it (including a
    /// transient's) resolve further scoped components against the same scope
    /// through either plain `resolve` or the explicit `resolveInActiveScope`.
    public func resolve<T>(_ type: T.Type = T.self, qualifier: String? = nil, in scope: Scope) throws -> T {
        guard frozenStorage != nil else {
            preconditionFailure("Scoped resolution requires a frozen container — scopes exist only in the resolution phase (§3).")
        }
        return try Scope.$active.withValue(scope) {
            try resolve(type, qualifier: qualifier)
        }
    }

    private func resolveAny(key: ComponentKey) throws -> Any {
        if let frozen = frozenStorage {
            guard let registration = frozen.registrations[key] else {
                throw ResolutionError.notRegistered(key.description)
            }
            switch registration.scope {
            case .singleton:
                // Every singleton was constructed at freeze(); this is the
                // pure, lock-free read the two-phase model exists to enable.
                guard let instance = frozen.singletons[key] else {
                    // Unreachable by construction; named for debuggability.
                    throw ResolutionError.notRegistered(key.description)
                }
                return instance
            case .transient:
                return try constructTracked(registration)
            case .scoped:
                // Delta 12: plain resolve rides the ambient scope when one is
                // bound (by resolve(_:in:), which covers the whole resolution
                // synchronously). This is what lets @Autowired — which always
                // expands to plain resolve — wire a scoped component into another
                // scoped component: the outer resolution binds the scope, the
                // generated init's resolve lands here, and both instances
                // share the scope. With no ambient scope the error is
                // unchanged, so the captive-dependency guarantee holds: a
                // singleton factory at freeze() has no ambient scope and
                // fails loudly.
                guard let scope = Scope.active else {
                    throw ResolutionError.scopeRequired(key.description)
                }
                return try scope.instance(for: key) {
                    try constructTracked(registration)
                }
            }
        }

        // Mid-freeze: eager singleton construction resolves dependencies
        // against the in-progress maps. Still single-threaded (freeze runs
        // on the bootstrap thread), so plain vars remain sound here.
        precondition(
            phase == .freezing,
            "resolve() called during the registration phase — resolution begins at freeze() (§2.1)."
        )
        guard let registration = registrations[key] else {
            throw ResolutionError.notRegistered(key.description)
        }
        switch registration.scope {
        case .singleton:
            if let cached = singletonsUnderConstruction[key] { return cached }
            let instance = try constructTracked(registration)
            singletonsUnderConstruction[key] = instance
            return instance
        case .transient:
            return try constructTracked(registration)
        case .scoped:
            throw ResolutionError.scopeRequired(key.description)
        }
    }

    // MARK: - Runtime cycle detection (§2.2, dynamic-factory fallback)

    private enum ResolutionStack {
        // TaskLocal rather than thread-local: correct under Swift's
        // cooperative pool (a task may hop threads at suspension points) and
        // it binds synchronously, so it also covers the mid-freeze path.
        @TaskLocal static var frames: [String] = []
    }

    private func constructTracked(_ registration: Registration) throws -> Any {
        let name = registration.key.description
        let frames = ResolutionStack.frames
        if frames.contains(name) {
            throw ResolutionError.circularDependency(frames + [name])
        }
        return try ResolutionStack.$frames.withValue(frames + [name]) {
            try registration.factory(self)
        }
    }

    // MARK: - Introspection (§6)

    public func allRegistrations() -> [ComponentDescriptor] {
        if let frozen = frozenStorage {
            return frozen.order.compactMap { frozen.registrations[$0]?.descriptor }
        }
        // Pre-freeze view kept readable for tooling/tests; harmless because
        // it is only reachable from the single-threaded registration phase.
        return order.compactMap { registrations[$0]?.descriptor }
    }

    // MARK: - Module health (§6.1)

    internal func beginHealthTracking(moduleNames: [String]) {
        healthState.withLock { state in
            state.order = moduleNames
            state.map = Dictionary(uniqueKeysWithValues: moduleNames.map { ($0, ModuleHealth.notStarted) })
        }
    }

    internal func setHealth(_ moduleName: String, _ health: ModuleHealth) {
        healthState.withLock { state in
            if state.map[moduleName] == nil { state.order.append(moduleName) }
            state.map[moduleName] = health
        }
    }

    public func moduleStatuses() -> [ModuleStatus] {
        healthState.withLock { state in
            state.order.compactMap { name in
                state.map[name].map { ModuleStatus(moduleName: name, health: $0) }
            }
        }
    }
}
