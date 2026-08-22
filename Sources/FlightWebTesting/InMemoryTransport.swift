import FlightCore
import FlightWeb
import ServiceLifecycle
import Synchronization

/// A `ServerTransport` that touches no socket (§5.4): requests go in through
/// `InMemoryTransportHub.execute`, responses come back, and the full
/// bootstrap path — module DAG, freeze, `FlightWebModule`, dispatch assembly,
/// ServiceGroup — is exercised for real. Its `run()` parks until graceful
/// shutdown or cancellation, like any suspending `Service` (§5.3).
///
///     try await bootstrap(configuration: config,
///                         modules: [FlightWebModule<InMemoryTransport>.self, AppModule.self])
///     // from another task:
///     let response = try await InMemoryTransportHub.execute(Request(path: "/users/1"))
public struct InMemoryTransport: ServerTransport {
    public struct Configuration: ServerTransportConfiguration {
        public init() {}
        public init(configuration: FlightCore.Configuration) throws {}
    }

    private let dispatch: Dispatch

    public init(configuration: Configuration, dispatch: @escaping Dispatch) {
        self.dispatch = dispatch
    }

    public func run() async throws {
        InMemoryTransportHub.register(dispatch)
        defer { InMemoryTransportHub.unregister() }
        // Suspends until graceful shutdown; throws CancellationError on
        // task-level cancellation. Either way the app is winding down.
        try await gracefulShutdown()
    }
}

/// Test-side access to the most recently started `InMemoryTransport`. A
/// process-global, deliberately: the transport instance is constructed deep
/// inside `FlightWebModule`'s service and tests need a handle to it. One
/// in-memory-bootstrapped app per process at a time.
public enum InMemoryTransportHub {
    private static let current = Mutex<Dispatch?>(nil)

    public enum HubError: Error, CustomStringConvertible {
        case noTransportRunning
        public var description: String {
            "No InMemoryTransport is running — bootstrap with FlightWebModule<InMemoryTransport> first (and await readiness)."
        }
    }

    static func register(_ dispatch: @escaping Dispatch) {
        current.withLock { $0 = dispatch }
    }

    static func unregister() {
        current.withLock { $0 = nil }
    }

    public static var isRunning: Bool {
        current.withLock { $0 != nil }
    }

    /// Suspends (polling) until the transport registers — bridges the gap
    /// between launching bootstrap in a task and the ServiceGroup actually
    /// starting the web service.
    public static func waitUntilRunning(timeout: Duration = .seconds(5)) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !isRunning {
            guard clock.now < deadline else { throw HubError.noTransportRunning }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    public static func execute(_ request: Request) async throws -> Response {
        guard let dispatch = current.withLock({ $0 }) else {
            throw HubError.noTransportRunning
        }
        return await dispatch(request)
    }
}
