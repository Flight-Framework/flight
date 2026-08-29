import Synchronization

/// The Flight DI container.
///
/// ## The two-phase model, as implemented
///
/// - **Registration phase** — from `init()` until `freeze()`. Strictly
///   single-threaded *by contract*: bootstrap runs every module's
///   `configure(_:)` serially, in module-DAG order. Registration state is
///   therefore held in plain vars guarded by preconditions, not locks — a
///   lock here would launder a contract violation into silent misbehaviour
///   instead of a loud trap.
/// - **Resolution phase** — from the moment `freeze()` returns.
///   `frozenStorage` is written exactly once, and every concurrent reader
///   lives in a task created *after* `freeze()` returns: bootstrap hands
///   services to the `ServiceGroup` only once the container is frozen. Task
///   creation establishes the happens-before edge, so the publication is
///   ordered without any fence, lock, or atomic, and post-freeze resolution
///   is a plain dictionary read. The `nonisolated(unsafe)` below is the
///   single, documented place where that argument is load-bearing.
///
/// The contract holds under Flight's own bootstrap and is unenforceable for
/// an arbitrary embedder: a reader task created *before* `freeze()` returns
/// would be a data race this design cannot detect. That is the trade, stated
/// rather than hidden.
///
/// `@unchecked Sendable` is justified by exactly the reasoning above; if the
/// two-phase contract ever changes, this annotation is the first thing to
/// re-audit.
public final class Container: @unchecked Sendable {

    // MARK: - Registration-phase state (single-threaded by contract)

    private enum Phase { case registering, freezing, frozen, failed }

    /// The first duplicate registration seen, reported by ``freeze()``.
    ///
    /// Recorded rather than trapped: generated code and hand-written code can
    /// legitimately collide, and that is a wiring problem for the bootstrap
    /// sequence to report — not a reason to abort the process from inside a
    /// registration call the developer did not write.
    private var duplicateRegistration: ComponentKey?

    /// Keys claimed by ``override(_:qualifier:scope:stereotype:factory:)``.
    /// A later `register` for one of these is discarded rather than recorded
    /// as a duplicate — that is the whole point of an override, and it is why
    /// overriding works regardless of whether it runs before or after the
    /// module that registers the real component.
    private var overriddenKeys: Set<ComponentKey> = []
    private var phase: Phase = .registering
    private var registrations: [ComponentKey: Registration] = [:]
    private var order: [ComponentKey] = []
    private var singletonsUnderConstruction: [ComponentKey: Any] = [:]

    /// Stamped by bootstrap around each module's `configure` call so that
    /// `ComponentDescriptor.sourceModule` requires nothing from module authors.
    internal var currentSourceModule: String = "<direct>"

    // MARK: - Post-freeze state (write-once, then read-only)

    nonisolated(unsafe) private var frozenStorage: FrozenStorage?

    // MARK: - Module health — mutated during the service-run phase,
    // so unlike component storage this genuinely needs synchronization.

    private struct HealthState {
        var order: [String] = []
        var map: [String: ModuleHealth] = [:]
    }
    private let healthState = Mutex(HealthState())

    public init() {}

    // MARK: - Registration

    /// Only callable during the registration phase. Traps if called after
    /// `freeze()` — programmer error, not a runtime condition.
    public func register<T: Sendable>(
        _ type: T.Type,
        qualifier: String? = nil,
        scope: Lifetime,
        stereotype: Stereotype = .component,
        factory: @escaping @Sendable (Container) throws -> T
    ) {
        precondition(
            phase == .registering,
            "Container.register called after freeze(). Registration is only legal during the bootstrap registration phase."
        )
        let key = ComponentKey(type, qualifier: qualifier)
        // An override already claimed this key: the real registration is
        // deliberately dropped, and is not a duplicate.
        if overriddenKeys.contains(key) { return }
        if registrations[key] != nil {
            // Reachable without a hand-written mistake: a generated existential
            // bridge can collide with a hand-written registration, and that is
            // a wiring problem to report, not a reason to abort the process.
            duplicateRegistration = duplicateRegistration ?? key
            return
        }
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

    /// Registers `factory` for this key, replacing anything already there and
    /// suppressing anything registered for it later.
    ///
    /// This exists for tests. The value of dependency injection here is that a
    /// suite can run the real controller, the real routing, and the real
    /// middleware while swapping the one seam that would otherwise need a
    /// database, a network, or a clock. Without an override, doing that means
    /// hand-rebuilding the object graph in every test module — and the obvious
    /// alternative, registering a fake alongside the real module, fails at
    /// `freeze()` with a duplicate-registration error whose advice ("give one
    /// of them a qualifier") is wrong for this situation.
    ///
    ///     let container = try TestContainer.build {
    ///         AppModule()
    ///     } overriding: { container in
    ///         container.override((any UserRepositoryProtocol).self, scope: .scoped) { _ in
    ///             InMemoryUsers()
    ///         }
    ///     }
    ///
    /// Order-independent by design: overriding before or after the module that
    /// registers the real component gives the same result, so a test never has
    /// to reason about module DAG ordering to swap one dependency.
    ///
    /// Calling it twice for the same key is last-wins, not an error — a suite
    /// refining an override from a shared helper is doing something reasonable.
    public func override<T: Sendable>(
        _ type: T.Type,
        qualifier: String? = nil,
        scope: Lifetime,
        stereotype: Stereotype = .component,
        factory: @escaping @Sendable (Container) throws -> T
    ) {
        precondition(
            phase == .registering,
            "Container.override called after freeze(). Overrides are only legal during the registration phase."
        )
        let key = ComponentKey(type, qualifier: qualifier)
        overriddenKeys.insert(key)

        // A real registration may already be present, if the module ran first.
        if registrations[key] != nil {
            registrations[key] = nil
            order.removeAll { $0 == key }
            // It was legitimately replaced, so it must not be reported as the
            // collision that failed the freeze.
            if duplicateRegistration == key { duplicateRegistration = nil }
        }

        let descriptor = ComponentDescriptor(
            typeName: key.typeName,
            scope: scope,
            sourceModule: "<override>",
            qualifier: qualifier,
            stereotype: stereotype
        )
        registrations[key] = Registration(key: key, scope: scope, descriptor: descriptor) { c in
            try factory(c)
        }
        order.append(key)
    }

    /// Called once by bootstrap after all modules have configured.
    /// Irreversible for the lifetime of the process.
    ///
    /// Deviation from the spec doc's `freeze()` signature, deliberately:
    /// singletons are constructed eagerly *here* (that eagerness is what makes
    /// post-freeze resolution a pure read), and a factory failure at startup
    /// must surface as an error to the already-throwing bootstrap sequence,
    /// not a trap.
    /// - Throws: whatever an eager singleton's factory throws. On failure the
    /// container moves to a terminal failed state: it reports
    /// ``isFrozen`` as `false`, refuses further registration, and refuses to
    /// resolve. Previously a thrown `freeze()` left the container mid-freeze
    /// — `isFrozen` said `false` while `resolve` happily handed out
    /// partially-constructed singletons.
    public func freeze() throws {
        precondition(
            phase == .registering,
            phase == .failed
                ? "freeze() called on a container whose previous freeze() failed. Build a new container."
                : "freeze() called more than once."
        )
        if let duplicate = duplicateRegistration {
            phase = .failed
            throw BootstrapError.duplicateRegistration(duplicate.description)
        }
        phase = .freezing
        do {
            for key in order where registrations[key]?.scope == .singleton {
                _ = try resolveAny(key: key)
            }
        } catch {
            phase = .failed
            singletonsUnderConstruction = [:]
            throw error
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

    /// Safe to call concurrently post-freeze; no isolation required.
    /// Throws `ResolutionError.notRegistered` as the fallback for genuinely
    /// dynamic resolution — the macro-generated path is validated at
    /// compile time and should never hit it.
    public func resolve<T: Sendable>(_ type: T.Type = T.self, qualifier: String? = nil) throws -> T
    {
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

    /// Scoped resolution. `.singleton`/`.transient` components resolved through
    /// this overload behave exactly as plain `resolve` — a component's scope is a
    /// property of its registration, not of the call site.
    ///
    /// The whole resolution runs with `Scope.active` bound to `scope`, and
    /// plain `resolve` consults that binding for `.scoped` registrations — so
    /// this overload is exactly "bind the scope, then resolve". Factories
    /// underneath it (including a
    /// transient's) resolve further scoped components against the same scope
    /// through either plain `resolve` or the explicit `resolveInActiveScope`.
    public func resolve<T: Sendable>(
        _ type: T.Type = T.self, qualifier: String? = nil, in scope: Scope
    ) throws -> T {
        guard frozenStorage != nil else {
            preconditionFailure(
                "Scoped resolution requires a frozen container — scopes exist only in the resolution phase."
            )
        }
        return try Scope.$active.withValue(scope) {
            try resolve(type, qualifier: qualifier)
        }
    }

    /// The container resolves to itself.
    ///
    /// Not a registration — a fallback *after* the lookup misses, so the
    /// container never appears in its own singleton map. Storing it there
    /// would be a strong reference cycle: a container that outlives the
    /// process is fine, but a test that builds a thousand of them leaks a
    /// thousand.
    ///
    /// After rather than before, because hand-registering
    /// `Container.self { c in c }` was the workaround before this existed,
    /// and applications did it. Intercepting ahead of the lookup would make
    /// those registrations dead code that still looks wired — and would
    /// silently return the wrong container to anyone deliberately registering
    /// a different one. A registration that is there still wins; this only
    /// answers when nothing else does.
    ///
    /// This exists because some components genuinely need it. A channel
    /// lives as long as a browser tab and a scheduled job runs on its own
    /// clock; neither is inside a request, and both need request-scoped
    /// repositories, which means opening a scope of their own. The gateway
    /// pattern that does it has to hold the container, and before this it
    /// could only be built by hand-writing a factory — one per gateway,
    /// every one of them the same three lines.
    ///
    /// It is still the escape hatch and not the habit. A component that
    /// resolves everything from a captured container has opted out of the
    /// wiring being checked at build time, and reads like a service locator
    /// because it is one. Inject what you need; reach for this when what you
    /// need is a scope.
    private static let selfKey = ComponentKey(Container.self, qualifier: nil)

    private func resolveAny(key: ComponentKey) throws -> Any {
        if let frozen = frozenStorage {
            guard let registration = frozen.registrations[key] else {
                if key == Self.selfKey { return self }
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
            "resolve() called during the registration phase — resolution begins at freeze()."
        )
        guard let registration = registrations[key] else {
            if key == Self.selfKey { return self }
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

    // MARK: - Runtime cycle detection

    private enum ResolutionStack {
        // TaskLocal rather than thread-local: correct under Swift's
        // cooperative pool (a task may hop threads at suspension points) and
        // it binds synchronously, so it also covers the mid-freeze path.
        //
        // Keys, not demangled names. `ComponentKey.description` goes through
        // `String(reflecting:)` — the exact cost `ComponentKey`'s lazy
        // `typeName` exists to avoid, and which its own comment says
        // "dominated resolve, which is on the hot path of every request".
        // Tracking by name paid it on every scoped and transient
        // construction, once per component per request, to build a string
        // only the cycle diagnostic ever reads. A `ComponentKey` is an
        // `ObjectIdentifier` and an optional `String`; comparing one is a
        // pointer compare.
        @TaskLocal static var frames: [ComponentKey] = []
    }

    private func constructTracked(_ registration: Registration) throws -> Any {
        let key = registration.key
        let frames = ResolutionStack.frames
        if frames.contains(key) {
            // Demangled here and only here — where there is a cycle to name.
            throw ResolutionError.circularDependency((frames + [key]).map(\.description))
        }
        return try ResolutionStack.$frames.withValue(frames + [key]) {
            try registration.factory(self)
        }
    }

    // MARK: - Introspection

    public func allRegistrations() -> [ComponentDescriptor] {
        if let frozen = frozenStorage {
            return frozen.order.compactMap { frozen.registrations[$0]?.descriptor }
        }
        // Pre-freeze view kept readable for tooling/tests; harmless because
        // it is only reachable from the single-threaded registration phase.
        return order.compactMap { registrations[$0]?.descriptor }
    }

    // MARK: - Module health

    internal func beginHealthTracking(moduleNames: [String]) {
        healthState.withLock { state in
            state.order = moduleNames
            state.map = Dictionary(
                uniqueKeysWithValues: moduleNames.map { ($0, ModuleHealth.notStarted) })
        }
    }

    /// Records a module's health from outside its own lifecycle.
    ///
    /// Core writes this itself — `.running` once a module configures,
    /// `.failed` if its `Service.run()` throws — and that was the whole of
    /// what anything downstream could ever see. A module that is *up* but has
    /// lost its database had no way to say so, which made "a module that
    /// cannot reach its database reports so" true only in the sense that a
    /// crashing service reports. This is the seam that makes it true
    /// properly: report the state, and `moduleStatuses()` and everything
    /// built on it pick it up.
    ///
    /// Safe to call at any time, from any task. Nothing polls it and nothing
    /// runs a check for you — the reporting cadence is the reporter's to
    /// choose, which is what keeps checks off the request path.
    public func reportHealth(_ health: ModuleHealth, forModule moduleName: String) {
        setHealth(moduleName, health)
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
