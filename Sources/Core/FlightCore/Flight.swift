import Logging
import ServiceLifecycle

/// The namespace for Flight's top-level entry points.
///
/// These were free functions once. `bootstrap` and `assemble` are useful
/// names, and a foundation package that every other module imports has no
/// business claiming them in every adopter's global scope — an application
/// with its own `bootstrap()` would collide with one it never asked for.
///
/// ```swift
/// try await Flight.bootstrap(
///     configuration: try Configuration.load(),
///     modules: [WebModule.self, DataModule.self]
/// )
/// ```
public enum Flight {

    /// Builds and freezes the container, then returns it alongside the
    /// services its modules registered — without running anything.
    ///
    /// The seam for tests and for embedders that drive the lifecycle
    /// themselves. Use ``bootstrap(configuration:modules:logger:)`` to run.
    ///
    /// ```swift
    /// let app = try Flight.assemble(configuration: config, modules: [AppModule.self])
    /// let service = try app.container.resolve(UserService.self)
    /// ```
    ///
    /// - Throws: ``BootstrapError`` if module ordering fails or an eager
    /// singleton's factory throws.
    public static func assemble(
        configuration: Configuration,
        modules: [any FlightModule.Type]
    ) throws -> AssembledApplication {
        try _flightAssemble(configuration: configuration, modules: modules)
    }

    /// Assembles the application and runs it under a `ServiceGroup` until
    /// shutdown.
    ///
    /// This is the whole of `main`. It installs signal handling, runs every
    /// registered service, and returns when the group shuts down.
    ///
    /// ```swift
    /// @main
    /// struct App {
    ///     static func main() async throws {
    ///         try await Flight.bootstrap(
    ///             configuration: try Configuration.load(),
    ///             modules: [WebModule.self, DataModule.self]
    ///         )
    ///     }
    /// }
    /// ```
    public static func bootstrap(
        configuration: Configuration,
        modules: [any FlightModule.Type],
        logger: Logger = Logger(label: "flight.bootstrap")
    ) async throws {
        try await _flightBootstrap(
            configuration: configuration, modules: modules, logger: logger)
    }

    /// The order modules must be configured in, resolved from their declared
    /// dependencies.
    ///
    /// Deterministic: the same module set always produces the same order.
    ///
    /// - Throws: ``ModuleGraphError/cycle(_:)``, naming the cycle, when module
    ///   dependencies are circular. There is no missing-module failure: a
    ///   transitive dependency is pulled in automatically, so "declared but
    ///   absent from the list" is not a state this can be in.
    public static func resolveModuleOrder(
        _ modules: [any FlightModule.Type]
    ) throws -> [any FlightModule.Type] {
        try _flightResolveModuleOrder(modules)
    }
}
