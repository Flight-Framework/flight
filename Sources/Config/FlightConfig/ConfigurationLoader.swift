import Configuration
import FlightConfigCore
import Foundation

/// The bootstrap entry point — steps 1–5 of the app-wide sequence, which are
/// Flight Config's entire contribution:
///
/// ```
/// 1. FlightEnvironment.current()        — read FLIGHT_ENV
/// 2. Load flight.yaml                   — base layer (required)
/// 3. Load flight-{env}.yaml             — environment layer (optional file)
/// 4. Wrap the process environment       — env var layer
/// 5. Configuration(providers: [env, envFile, base]) — assembled, immutable
/// ```
///
/// Pure and synchronous — no async, no actor isolation, since this all runs
/// before any concurrent work exists in the app's lifetime. That is why the
/// files are read here and handed to `FlightYAMLSnapshot` already parsed,
/// rather than going through `FileProvider`'s `async` initializer: a
/// synchronous bootstrap is worth more to Flight than reusing that one
/// initializer, and both paths end at the same snapshot type.
extension Configuration {

    /// The base layer's file name: shared defaults across all environments.
    public static var baseFileName: String { FlightConfigFiles.base }

    /// The environment layer's file name for `environment`,
    /// e.g. `flight-prod.yaml`.
    public static func fileName(for environment: FlightEnvironment) -> String {
        FlightConfigFiles.environmentFile(for: environment)
    }

    /// Resolves the full layered configuration for the active environment.
    ///
    /// - Parameters:
    ///   - directory: Where `flight.yaml` / `flight-{env}.yaml` live.
    ///     Defaults to the process working directory — the deployment
    ///     convention (config ships next to the binary's launch point).
    ///   - environment: Overrides environment resolution. Defaults to nil,
    ///     meaning `FLIGHT_ENV` is read from `processEnvironment` —
    ///     the one place in an app's lifetime that variable is consulted.
    ///   - processEnvironment: The variables backing the env-var layer,
    ///     `FLIGHT_ENV` resolution, and `${VAR}` substitution. Defaults to
    ///     the real process environment; tests pass a dictionary, which
    ///     makes the entire load reproducible without touching global state.
    ///   - secrets: Which environment variables hold secrets. Marked values
    ///     are redacted in access logs and in provider descriptions — so a
    ///     dumped provider stack shows `FLIGHT_DATASOURCE_PASSWORD=<REDACTED>`.
    ///     Defaults to `.none`, preserving the previous behavior exactly.
    ///   - accessReporter: Receives an event per resolved key, from Flight's
    ///     own accessors as well as from `Configuration.reader`. Pass an
    ///     `AccessLogger` to log every config read at startup.
    ///   - additionalProviders: Extra providers, inserted *above* the env-var
    ///     layer so they win. The hook for sources this package defers —
    ///     Kubernetes secret directories, remote stores, CLI arguments.
    ///
    /// - Throws: `ConfigLoadError.missingBaseFile` when `flight.yaml` is
    ///   absent from `directory`, and the other `ConfigLoadError` cases for
    ///   files that exist but cannot be read or parsed.
    ///
    /// - Returns: The immutable `Configuration`, precedence-ordered
    ///   env vars → `flight-{env}.yaml` → `flight.yaml`, ready to hand to
    ///   `Container.bootstrap(configuration:)`.
    public static func load(
        from directory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        environment: FlightEnvironment? = nil,
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        secrets: SecretsSpecifier<String, String> = .none,
        accessReporter: (any AccessReporter)? = nil,
        additionalProviders: [any ConfigProvider] = []
    ) throws -> Configuration {
        // Step 1 — the single FLIGHT_ENV read.
        let active = environment ?? FlightEnvironment.current(from: processEnvironment)
        let substitution = EnvironmentSubstitutionPolicy.resolve(processEnvironment)
        let fileManager = FileManager.default

        // Step 2 — base layer, required.
        let baseURL = directory.appendingPathComponent(baseFileName)
        guard fileManager.fileExists(atPath: baseURL.path) else {
            throw ConfigLoadError.missingBaseFile(expectedPath: baseURL.path)
        }
        let base = try yamlProvider(contentsOf: baseURL, substitution: substitution)

        // Step 3 — environment layer, optional. A missing file is not an
        // error: an environment need not override anything.
        let environmentURL = directory.appendingPathComponent(fileName(for: active))
        let environmentLayer: (any ConfigProvider)? = fileManager.fileExists(atPath: environmentURL.path)
            ? try yamlProvider(contentsOf: environmentURL, substitution: substitution)
            : nil

        // Step 4 — env var layer. `prefixKeys(with: "flight")` reproduces the
        // The documented transform exactly: the provider joins components with `_` and
        // uppercases, so `datasource.pool_size` under a `flight` prefix
        // encodes to FLIGHT_DATASOURCE_POOL_SIZE.
        let variables = EnvironmentVariablesProvider(
            environmentVariables: processEnvironment,
            secretsSpecifier: secrets
        ).prefixKeys(with: "flight")

        // Step 5 — assemble, highest precedence first.
        var providers: [any ConfigProvider] = additionalProviders
        providers.append(variables)
        if let environmentLayer {
            providers.append(environmentLayer)
        }
        providers.append(base)
        return Configuration(
            providers: providers, environment: active, accessReporter: accessReporter
        )
    }

    /// Reads one YAML layer from disk into an in-memory provider.
    ///
    /// The parse happens here, synchronously, and the resulting snapshot is
    /// wrapped in a provider that serves it — the same `FlightYAMLSnapshot`
    /// a `FileProvider<FlightYAMLSnapshot>` would build, minus the `async`.
    private static func yamlProvider(
        contentsOf url: URL,
        substitution: EnvironmentSubstitutionPolicy
    ) throws -> any ConfigProvider {
        let document = try FlightYAMLDocument(contentsOf: url, substitution: substitution)
        return FlightYAMLProvider(
            snapshot: FlightYAMLSnapshot(document: document, providerName: url.lastPathComponent)
        )
    }
}
