// Compile-time guard: this target exists only when the "Web" trait is on.
// Both traits are opt-in — Package.swift declares `.default(enabledTraits: [])`
// — so this fires for any consumer that did not name "Web", and for a root
// build without --enable-all-traits. The comment used to describe the
// opposite polarity, which would have made the guard look like a corner case
// rather than the default path.
#if !Web
#error("""
    FlightWebTesting requires the "Web" trait.

    Consuming flight:
        .package(url: "https://github.com/Swift-Flight/flight.git", \
                 from: "0.10.0", traits: ["Web"])

    Building flight itself:
        swift build --enable-all-traits
    """)
#endif
