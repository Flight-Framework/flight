import FlightCore
import ServiceLifecycle
import Synchronization

// MARK: - Hand-registered component types
//
// Container/Scope/bootstrap tests wire these by hand so their results say
// nothing about macro correctness — the macro layer has its own suites.

final class Alpha: Sendable {
    init() {}
}

final class Beta: Sendable {
    let alpha: Alpha
    init(alpha: Alpha) { self.alpha = alpha }
}

final class Gamma: Sendable {
    init() {}
}

/// Thread-safe counter for observing factory invocations.
final class InvocationCounter: Sendable {
    private let count = Mutex(0)
    func increment() { count.withLock { $0 += 1 } }
    var value: Int { count.withLock { $0 } }
}

// MARK: - LoggingModule
//
// The second, deliberately trivial FlightModule conformance required by §4:
// its existence validates that the abstraction isn't secretly shaped around
// the web starter. It registers one component and owns no service.

public final class TestLogSink: Sendable {
    private let lines = Mutex<[String]>([])
    public init() {}
    public func log(_ line: String) { lines.withLock { $0.append(line) } }
    public var captured: [String] { lines.withLock { $0 } }
}

public struct LoggingModule: FlightModule {
    public init() {}

    public func configure(_ container: Container) throws {
        container.register(TestLogSink.self, scope: .singleton) { _ in TestLogSink() }
    }
}

// MARK: - FakeServerModule
//
// A service-owning module standing in for the web starter: depends on
// LoggingModule, registers a component that consumes LoggingModule's component, and
// exposes a Service.

public final class FakeServer: Sendable {
    public let sink: TestLogSink
    public init(sink: TestLogSink) { self.sink = sink }
}

/// A Service that runs until cancelled, or throws immediately if told to.
struct ControllableService: Service {
    enum Behavior { case runUntilCancelled, failImmediately }
    let behavior: Behavior

    func run() async throws {
        switch behavior {
        case .runUntilCancelled:
            // Idiomatic ServiceLifecycle shape: park until cancellation.
            try await Task.sleep(for: .seconds(3600))
        case .failImmediately:
            throw TestServiceError.boom
        }
    }
}

enum TestServiceError: Error { case boom }

public struct FakeServerModule: FlightModule {
    public static var dependencies: [any FlightModule.Type] { [LoggingModule.self] }

    public init() {}

    public func configure(_ container: Container) throws {
        container.register(FakeServer.self, scope: .singleton) { c in
            FakeServer(sink: try c.resolve(TestLogSink.self))
        }
    }

    public var service: (any Service)? {
        ControllableService(behavior: .runUntilCancelled)
    }
}

/// A module whose Service fails as soon as it runs — exercises the
/// ModuleHealth .failed transition (§6.1).
public struct FailingServiceModule: FlightModule {
    public init() {}
    public func configure(_ container: Container) throws {}
    public var service: (any Service)? {
        ControllableService(behavior: .failImmediately)
    }
}

/// A bounded, run-to-completion service module (delta 9): its Service returns
/// after doing its work, and .endsApp tells bootstrap that finishing is
/// success (graceful group shutdown), not serviceFinishedUnexpectedly.
public struct OneShotModule: FlightModule {
    struct FinishImmediately: Service {
        func run() async throws {}
    }
    public init() {}
    public func configure(_ container: Container) throws {}
    public var service: (any Service)? { FinishImmediately() }
    public var serviceCompletion: ServiceCompletionPolicy { .endsApp }
}

/// A module that throws during configure — exercises bootstrap's
/// moduleConfigurationFailed path.
public struct BrokenConfigureModule: FlightModule {
    public init() {}
    public func configure(_ container: Container) throws {
        throw TestServiceError.boom
    }
}

// MARK: - Diamond module graph (A ← B, A ← C, {B,C} ← D)

public struct ModA: FlightModule {
    public init() {}
    public func configure(_ container: Container) throws {}
}
public struct ModB: FlightModule {
    public static var dependencies: [any FlightModule.Type] { [ModA.self] }
    public init() {}
    public func configure(_ container: Container) throws {}
}
public struct ModC: FlightModule {
    public static var dependencies: [any FlightModule.Type] { [ModA.self] }
    public init() {}
    public func configure(_ container: Container) throws {}
}
public struct ModD: FlightModule {
    public static var dependencies: [any FlightModule.Type] { [ModB.self, ModC.self] }
    public init() {}
    public func configure(_ container: Container) throws {}
}

// MARK: - Cyclic module graph (X ↔ Y)

public struct CycleModX: FlightModule {
    public static var dependencies: [any FlightModule.Type] { [CycleModY.self] }
    public init() {}
    public func configure(_ container: Container) throws {}
}
public struct CycleModY: FlightModule {
    public static var dependencies: [any FlightModule.Type] { [CycleModX.self] }
    public init() {}
    public func configure(_ container: Container) throws {}
}
