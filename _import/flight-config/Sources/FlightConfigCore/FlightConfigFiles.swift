/// The config file names the layering is built from.
///
/// These live in `FlightConfigCore` rather than beside `Configuration.load`
/// because Flight Core's `flight-registration-gen` build tool needs to find
/// `flight.yaml` to check `@ConfigValue` keys against it, and that tool links
/// only the dependency-free core. `Configuration.baseFileName` and
/// `Configuration.fileName(for:)` forward here, so both spellings agree by
/// construction.
public enum FlightConfigFiles {

    /// The base layer's file name: shared defaults across all environments.
    public static let base = "flight.yaml"

    /// The environment layer's file name for `environment`,
    /// e.g. `flight-prod.yaml`.
    public static func environmentFile(for environment: FlightEnvironment) -> String {
        "flight-\(environment.rawValue).yaml"
    }
}
