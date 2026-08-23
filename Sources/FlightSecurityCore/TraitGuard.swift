// Compile-time guard: this target exists only when the "Security" trait is on.
// "Security" is a default trait, so this fires only for a consumer that opted
// out with `traits: []`, or for a root build with defaults disabled.
#if !Security
#error("""
    FlightSecurityCore requires the "Security" trait.

    Consuming flight:
        .package(url: "https://github.com/Swift-Flight/flight.git", \
                 from: "0.1.0", traits: ["Security"])

    Building flight itself:
        swift build --enable-all-traits
    """)
#endif
