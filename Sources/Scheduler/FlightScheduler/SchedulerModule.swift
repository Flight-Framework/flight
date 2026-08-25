import FlightCore
import Foundation
import ServiceLifecycle

/// Registers the scheduler.
///
/// ```swift
/// try await Flight.bootstrap(
///     configuration: try Configuration.load(),
///     modules: [FlightSchedulerModule.self, AppModule.self]
/// )
/// ```
///
/// A class, because it stashes the container during `configure` for the
/// service to resolve from post-freeze — the same shape as every other
/// service-owning module here.
///
/// Registers no coordinator of its own. A deployment that needs `.once` to
/// mean once across several servers registers a ``JobCoordinator`` from a
/// module that has something to coordinate *through* — a database, a cache —
/// exactly as a distributed PubSub deployment registers an adapter.
public final class FlightSchedulerModule: FlightModule, @unchecked Sendable {
    private var container: Container?

    public init() {}

    public func configure(_ container: Container) throws {
        self.container = container
        container.register(SchedulerStatus.self, scope: .singleton) { _ in
            SchedulerStatus()
        }
    }

    public var service: (any Service)? {
        container.map { SchedulerService(container: $0) }
    }
}
