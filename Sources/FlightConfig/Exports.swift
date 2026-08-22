/// `FlightConfigCore` re-exported.
///
/// The package is split so that Flight Core's `flight-registration-gen` build
/// tool can link the parser without dragging swift-configuration (and its
/// transitive swift-system / swift-collections / swift-service-lifecycle) into
/// every consumer's build graph. That split is a build-graph concern and
/// should not be an import-statement concern: `import FlightConfig` still
/// yields the whole API — `ConfigDecodable`, the error types,
/// `FlightEnvironment`, the sources, the YAML parser — exactly as before, and
/// Flight Core's own `@_exported import FlightConfig` keeps working unchanged.
@_exported import FlightConfigCore
