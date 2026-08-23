// swift-tools-version: 6.1
// Flight Actuator — HTTP introspection surface for a running Flight app
// A leaf package: a consumer of Core/Web/Config,
// not infrastructure anything else builds on.
import PackageDescription

let package = Package(
    name: "flight-actuator",
    platforms: [
        // macOS 15 for Synchronization.Mutex, same floor as flight-core.
        .macOS(.v15)
    ],
    products: [
        .library(name: "FlightActuator", targets: ["FlightActuator"])
    ],
    dependencies: [
        .package(path: "../flight-web"),
        .package(path: "../../Core/flight-core"),
        // Tests conform a fixture module's service to ServiceLifecycle.Service
        // to exercise the real health-tracking path; already in the graph via
        // flight-core.
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.6.0"),
    ],
    targets: [
        .target(
            name: "FlightActuator",
            dependencies: [
                .product(name: "FlightWeb", package: "flight-web"),
                .product(name: "FlightCore", package: "flight-core"),
            ],
            swiftSettings: [
                // Strict concurrency is the default under tools 6.x; kept
                // explicit as documentation of intent, matching the rest of
                // the Flight stack.
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "FlightActuatorTests",
            dependencies: [
                "FlightActuator",
                .product(name: "FlightWeb", package: "flight-web"),
                .product(name: "FlightWebTesting", package: "flight-web"),
                .product(name: "FlightCore", package: "flight-core"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ]
        ),
    ]
)
