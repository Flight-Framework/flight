// swift-tools-version: 6.2
// Flight Core — DI container + compile-time-first registration.
// See README.md for build status and known-risk notes.
import PackageDescription
import Foundation
import CompilerPluginSupport

let package = Package(
    name: "flight-core",
    platforms: [
        // macOS 15 is required for `Mutex` (Synchronization module) used in
        // Scope and health tracking. Linux with a Swift 6.1 toolchain is
        // unaffected by this stanza.
        .macOS(.v15)
    ],
    products: [
        .library(name: "FlightCore", targets: ["FlightCore"]),
        .plugin(name: "FlightRegistrationPlugin", targets: ["FlightRegistrationPlugin"]),
    ],
    dependencies: [
        // Flight Config — the one Flight package Core depends on (Core doc
        // header: "Depends on: Flight Config (Configuration)"). Since Config
        // moved onto swift-configuration it ships two products: FlightConfig
        // (the runtime facade, which pulls swift-configuration) and
        // FlightConfigCore (parser and vocabulary, still dependency-free).
        .package(path: "../../Config/flight-config"),
        // Dependency policy (§9): Apple-adjacent, SSWG-blessed only.
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.6.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
        // swift-syntax bumps its major with each Swift release; the open
        // range is the community convention for macro packages.
        .package(url: "https://github.com/swiftlang/swift-syntax.git", "601.0.0"..<"999.0.0"),
        // NOTE (§9): swift-collections is *allowed* by the dependency policy
        // but not yet needed — plain arrays/dictionaries cover the module DAG
        // and registration ordering. Add it when a measurement says to.
        // swift-metrics / swift-distributed-tracing: deferred until the first
        // lifecycle event actually emits a metric; adding facade deps with no
        // call sites would be speculative.
    ],
    targets: [
        .target(
            name: "FlightCore",
            dependencies: [
                "FlightCoreMacrosImpl",
                .product(name: "FlightConfig", package: "flight-config"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: [
                // Strict concurrency is the default under tools 6.x; kept
                // explicit as documentation of intent (§8).
                .swiftLanguageMode(.v6)
            ]
        ),
        .macro(
            name: "FlightCoreMacrosImpl",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
                .product(name: "SwiftDiagnostics", package: "swift-syntax"),
                .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
            ]
        ),
        // Code generator invoked by the build tool plugin. Kept free of
        // swift-argument-parser deliberately (one positional arg: manifest path).
        // FlightConfigCore: the generator parses flight.yaml with the *same*
        // parser the runtime uses, so the §5 compile-time key check can never
        // disagree with runtime resolution about what keys a file defines.
        // Core, not FlightConfig: a build tool's dependencies are paid for by
        // every consumer's build, and the key check needs the parser, not the
        // provider stack.
        .executableTarget(
            name: "flight-registration-gen",
            dependencies: [
                .product(name: "FlightConfigCore", package: "flight-config"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ]
        ),
        .plugin(
            name: "FlightRegistrationPlugin",
            capability: .buildTool(),
            dependencies: ["flight-registration-gen"]
        ),
        .testTarget(
            name: "FlightRegistrationGenTests",
            dependencies: ["flight-registration-gen"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "FlightCoreTests",
            dependencies: [
                "FlightCore",
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ]
        ),
        // Macro fixture suite (§5.4). XCTest, because assertMacroExpansion
        // ships in SwiftSyntaxMacrosTestSupport as XCTest-based.
        .testTarget(
            name: "FlightCoreMacroTests",
            dependencies: [
                "FlightCoreMacrosImpl",
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                // MacroSpec — carries declared conformances into assertMacroExpansion.
                .product(name: "SwiftSyntaxMacroExpansion", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
            ]
        ),
    ]
)

// Documentation tooling only, gated so consumers never resolve it.
if ProcessInfo.processInfo.environment["FLIGHT_CORE_BUILD_DOCS"] != nil {
    package.dependencies.append(
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.3.0")
    )
}
