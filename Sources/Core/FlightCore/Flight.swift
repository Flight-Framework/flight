import Logging
import ServiceLifecycle

#if canImport(Glibc)
    import Glibc
#elseif canImport(Darwin)
    import Darwin
#endif

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

    /// Assembles from modules already built, in dependency order.
    ///
    /// The type-based overload above instantiates modules itself, so every
    /// module must be constructible with no arguments — which is why a module
    /// reads configuration through the container rather than taking it as a
    /// parameter. This one takes what a caller already has, so a module is
    /// free to declare what it needs in its initializer and hold what it
    /// provides (COMPOSITION-MIGRATION.md D11).
    ///
    /// Ordered, because resolving the DAG is what the other overload uses the
    /// types for. A generated composition root has that order from the same
    /// `dependencies` walk, decided at build time.
    public static func assemble(
        configuration: Configuration,
        modules: [any FlightModule]
    ) throws -> AssembledApplication {
        try _flightAssemble(configuration: configuration, moduleInstances: modules)
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

    /// The whole of `main`: run the application, and if it cannot start, say
    /// why and exit non-zero.
    ///
    /// ```swift
    /// @main
    /// struct App {
    ///     static func main() async {
    ///         await Flight.run(
    ///             configuration: try Configuration.load(),
    ///             modules: [FlightWebModule<FlightTransport>.self, AppModule.self]
    ///         )
    ///     }
    /// }
    /// ```
    ///
    /// Same work as ``bootstrap(configuration:modules:logger:)``, and one
    /// difference: it does not throw. A `main` that does is the difference
    /// between
    ///
    /// ```
    /// flight: could not start.
    /// Configuration key 'datasource.primary.url' is not set in any source
    /// (active environment: prod). Add it to flight.yaml or flight-prod.yaml,
    /// or set the FLIGHT_DATASOURCE_PRIMARY_URL environment variable.
    /// ```
    ///
    /// and the same message under `Swift/ErrorType.swift:254: Fatal error:
    /// Error raised at top level:` followed by thirty lines of backtrace and
    /// a `Signal 4` — which is what a thrown error out of `main` produces,
    /// and what every deployment that mistypes a key currently sees. The
    /// message was always good; the frame around it said "this program
    /// crashed" about a configuration typo.
    ///
    /// The configuration is an autoclosure so that a *load* failure — a
    /// missing file, a `${VAR}` with nothing behind it — is reported the same
    /// way as a bootstrap failure rather than trapping at the call site.
    ///
    /// Exits `0` after a graceful shutdown, `1` on a startup failure. An
    /// embedder that wants the error rather than the exit uses `bootstrap`.
    /// `composedBy` is how a module gets to take what it needs.
    ///
    /// Without it, this instantiates every module from its type, so a module
    /// must be constructible with no arguments — which is why one reads
    /// configuration through the container rather than declaring it as a
    /// parameter. The build plugin generates a composer that constructs them
    /// in dependency order instead, and `flight new` writes the argument;
    /// `modules:` stays the declaration of which subsystems this application
    /// includes, and is what the plugin reads to know.
    ///
    /// Omit it and nothing changes: the type-based path is unchanged and
    /// remains supported.
    public static func run(
        configuration: @autoclosure @Sendable () throws -> Configuration,
        modules: [any FlightModule.Type],
        composedBy compose: (@Sendable (Configuration) throws -> [any FlightModule])? = nil,
        logger: Logger = Logger(label: "flight.bootstrap")
    ) async -> Never {
        do {
            let configuration = try configuration()
            if let compose {
                try await _flightBootstrap(
                    configuration: configuration, moduleInstances: try compose(configuration),
                    logger: logger)
            } else {
                try await bootstrap(
                    configuration: configuration, modules: modules, logger: logger)
            }
            exit(0)
        } catch {
            // Written straight to file descriptor 2 rather than through
            // Foundation: this file is in the module every other one imports,
            // and a startup message is not worth a dependency. (`stderr`
            // itself is a `var` in Glibc, which strict concurrency refuses.)
            // `String(reflecting:)`, not plain interpolation: PostgresNIO's
            // `description` is deliberately redacted ("Generic description to
            // prevent accidental leakage of sensitive data"), and the
            // reflected form names the host, the port and the errno — which
            // is the whole content of "why did it not start". Safe here
            // specifically: a startup failure has no user queries or bind
            // values in it, and the process is about to exit.
            let message = "flight: could not start.\n\(String(reflecting: error))\n"
            let bytes = Array(message.utf8)
            bytes.withUnsafeBufferPointer { buffer in
                var written = 0
                while written < buffer.count {
                    let result = write(2, buffer.baseAddress! + written, buffer.count - written)
                    if result <= 0 { break }
                    written += result
                }
            }
            exit(1)
        }
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

    /// Instances for `moduleTypes`, reusing anything in `supplying` and
    /// building the rest with `init()`.
    ///
    /// This is the one place a module gets built from its type alone, so it is
    /// the one place that can refuse. A module whose
    /// ``FlightModule/isTypeConstructible`` is false has no usable `init()`,
    /// and the walk reaches such a module most often as a *transitive*
    /// dependency the caller never named — which is why the failure has to say
    /// what to pass rather than trapping wherever the `init()` happens to be.
    ///
    /// - Throws: ``BootstrapError/moduleRequiresConstruction(module:)``.
    public static func instantiateModules(
        _ moduleTypes: [any FlightModule.Type],
        supplying supplied: [any FlightModule] = []
    ) throws -> [any FlightModule] {
        let byType = Dictionary(
            supplied.map { (ObjectIdentifier(type(of: $0)), $0) },
            uniquingKeysWith: { first, _ in first })
        return try moduleTypes.map { moduleType in
            if let instance = byType[ObjectIdentifier(moduleType)] { return instance }
            guard moduleType.isTypeConstructible else {
                throw BootstrapError.moduleRequiresConstruction(module: moduleType.moduleName)
            }
            return moduleType.init()
        }
    }
}
