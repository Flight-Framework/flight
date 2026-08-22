import FlightCore

// Presentation vocabulary over Core's introspection types (§3). Core keeps
// `ModuleHealth`/`Lifetime`/`Stereotype` free of rendering concerns; the
// labels both renderings share live here so JSON and SSR can never disagree
// about what a state is called.

extension ModuleHealth {
    /// True only for `.failed`. The predicate the design doc's own test
    /// leans on (§6) — checking health without pattern-matching an enum
    /// that carries a non-Equatable `any Error`.
    public var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    public var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    public var isNotStarted: Bool {
        if case .notStarted = self { return true }
        return false
    }

    /// Stable machine-readable label, shared by the JSON encoding and the
    /// SSR table: "notStarted" | "running" | "failed".
    public var actuatorLabel: String {
        switch self {
        case .notStarted: return "notStarted"
        case .running: return "running"
        case .failed: return "failed"
        }
    }

    /// The failure's description for `.failed`, nil otherwise.
    public var failureDescription: String? {
        if case .failed(let error) = self { return String(describing: error) }
        return nil
    }
}

extension Lifetime {
    /// "singleton" | "transient" | "scoped".
    public var actuatorLabel: String {
        switch self {
        case .singleton: return "singleton"
        case .transient: return "transient"
        case .scoped: return "scoped"
        }
    }
}

extension Stereotype {
    /// "component" | "service" | "repository" | "controller".
    public var actuatorLabel: String {
        switch self {
        case .component: return "component"
        case .service: return "service"
        case .repository: return "repository"
        case .controller: return "controller"
        }
    }

    /// Section heading for the SSR dashboard's layer grouping (Flight Core
    /// §5.1.1: the stereotype tag exists to feed exactly this grouping).
    var actuatorSectionTitle: String {
        switch self {
        case .component: return "Components"
        case .service: return "Services"
        case .repository: return "Repositories"
        case .controller: return "Controllers"
        }
    }

    /// Dashboard section order: entry points first, then business logic,
    /// data access, and generic components.
    static var actuatorSectionOrder: [Stereotype] {
        [.controller, .service, .repository, .component]
    }
}
