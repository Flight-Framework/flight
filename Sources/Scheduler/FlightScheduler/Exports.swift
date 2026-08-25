/// The cron engine lives in its own dependency-free target so the macro
/// plugin can validate expressions with the *same parser the runtime uses*,
/// rather than a copy kept in lockstep by discipline. Re-exported here so
/// applications import one module.
@_exported import FlightCronCore
