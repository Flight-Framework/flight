import FlightCore
import ServiceLifecycle
import Synchronization

// MARK: - Test modules (value form)
//
// Bootstrap tests construct these by hand — the composition root a real app
// generates does the same. A module holds what it provides; there is no
// container to register into.

public final class TestLogSink: Sendable {
    private let lines = Mutex<[String]>([])
    public init() {}
    public func log(_ line: String) { lines.withLock { $0.append(line) } }
    public var captured: [String] { lines.withLock { $0 } }
}

/// A trivial second `FlightModule` conformance: proves the abstraction is not
/// secretly shaped around the web module. Holds one component, owns no service.
public struct LoggingModule: FlightModule {
    public let sink = TestLogSink()
    public init() {}
}

// MARK: - A service-owning module

public final class FakeServer: Sendable {
    public let sink: TestLogSink
    public init(sink: TestLogSink) { self.sink = sink }
}

/// Runs until cancelled, or throws immediately if told to.
struct ControllableService: Service {
    enum Behavior { case runUntilCancelled, failImmediately }
    let behavior: Behavior

    func run() async throws {
        switch behavior {
        case .runUntilCancelled:
            try await Task.sleep(for: .seconds(3600))
        case .failImmediately:
            throw TestServiceError.boom
        }
    }
}

enum TestServiceError: Error { case boom }

/// Takes what it needs (the sink LoggingModule provides), holds what it
/// provides (the server), owns a run-until-cancelled service.
public struct FakeServerModule: FlightModule {
    public static var dependencies: [any FlightModule.Type] { [LoggingModule.self] }
    public let server: FakeServer
    public init(sink: TestLogSink) { self.server = FakeServer(sink: sink) }
    public var service: (any Service)? { ControllableService(behavior: .runUntilCancelled) }
}

/// A module whose Service fails as soon as it runs — exercises the
/// ModuleHealth .failed transition.
public struct FailingServiceModule: FlightModule {
    public init() {}
    public var service: (any Service)? { ControllableService(behavior: .failImmediately) }
}

/// A bounded, run-to-completion service module: `.endsApp` tells bootstrap
/// that finishing is success (graceful shutdown), not a failure.
public struct OneShotModule: FlightModule {
    struct FinishImmediately: Service {
        func run() async throws {}
    }
    public init() {}
    public var service: (any Service)? { FinishImmediately() }
    public var serviceCompletion: ServiceCompletionPolicy { .endsApp }
}
