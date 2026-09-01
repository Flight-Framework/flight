// Compile-time guard: this target exists only when the "Security" trait is on.
// Both traits are opt-in — Package.swift declares `.default(enabledTraits: [])`
// — so this fires for any consumer that did not name "Security", and for a root
// build without --enable-all-traits. The comment used to describe the
// opposite polarity, which would have made the guard look like a corner case
// rather than the default path.
#if !Security
#error("""
    FlightSecurityCore requires the "Security" trait.

    Consuming flight:
        .package(url: "https://github.com/Flight-Framework/flight.git", \
                 from: "0.11.0", traits: ["Security"])

    Building flight itself:
        swift build --enable-all-traits
    """)
#endif
