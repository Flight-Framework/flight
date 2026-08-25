// Compile-time guard: this target exists only when the "Web" trait is on.
// "Web" is a default trait, so this fires only for a consumer that opted
// out with `traits: []`, or for a root build with defaults disabled.
#if !Web
#error("""
    FlightChannels requires the "Web" trait.

    Consuming flight:
        .package(url: "https://github.com/Swift-Flight/flight.git", \
                 from: "0.1.0", traits: ["Web"])

    Building flight itself:
        swift build --enable-all-traits
    """)
#endif
