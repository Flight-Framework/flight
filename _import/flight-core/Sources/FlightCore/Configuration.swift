/// Flight Config's `Configuration`, re-exported.
///
/// This file was the placeholder seam while Flight
/// Config was a separate, not-yet-built package. The real package now lives
/// at `Config/flight-config` and Core depends on it; as designed, the seam
/// swap changed no Core API — `bootstrap(configuration:)`'s signature and the
/// `@ConfigValue` expansion still target exactly this surface.
///
/// The re-export means app targets `import FlightCore` and get the whole
/// config API (sources, loader, errors, `FlightEnvironment`) without a
/// second import. The typealias keeps `FlightCore.Configuration` — the
/// module-qualified name macro-generated code uses so expansions resolve in
/// any client module — pointing at the one real type.
@_exported import FlightConfig

public typealias Configuration = FlightConfig.Configuration
