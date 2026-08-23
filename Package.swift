// swift-tools-version: 6.0
// Flight Config — layered, environment-aware configuration resolution,
// built on Apple's swift-configuration.
//
// Two targets, split along the dependency line:
//
//   FlightConfigCore  the grammar and the vocabulary — the Flight-subset YAML
//                     parser, ${VAR} substitution, ConfigDecodable, the error
//                     types, FlightEnvironment. Depends on nothing, and must
//                     stay that way: Flight Core's `flight-registration-gen`
//                     build tool links it to check @ConfigValue keys against
//                     flight.yaml at compile time, and a build tool's
//                     dependencies are paid for by every consumer's build.
//
//   FlightConfig      the runtime — the `Configuration` facade, the
//                     swift-configuration provider bridge, and the loader.
//                     Re-exports FlightConfigCore, so `import FlightConfig`
//                     still yields the whole API and Flight Core's re-export
//                     chain is unchanged.
import PackageDescription
import Foundation

let package = Package(
    name: "flight-config",
    platforms: [
        // swift-configuration's floor (macOS 15 / iOS 18), which dominates the
        // macOS 13 this package needed on its own. flight-core is already at
        // macOS 15 for Synchronization.Mutex, so nothing regresses there.
        .macOS(.v15),
        .iOS(.v18),
        .tvOS(.v18),
        .watchOS(.v11),
        .visionOS(.v2),
    ],
    products: [
        .library(name: "FlightConfig", targets: ["FlightConfig"]),
        .library(name: "FlightConfigCore", targets: ["FlightConfigCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-configuration.git", from: "1.2.0")
    ],
    targets: [
        .target(
            name: "FlightConfigCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "FlightConfig",
            dependencies: [
                "FlightConfigCore",
                .product(name: "Configuration", package: "swift-configuration"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "FlightConfigTests",
            dependencies: ["FlightConfig"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)

// Documentation tooling only, gated so that consumers never resolve it.
//
//     SWIFT_CONFIG_BUILD_DOCS=1 swift package generate-documentation
if ProcessInfo.processInfo.environment["SWIFT_CONFIG_BUILD_DOCS"] != nil {
    package.dependencies.append(
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.3.0")
    )
}
