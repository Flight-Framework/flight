// swift-tools-version: 6.2
import CompilerPluginSupport
import Foundation
import PackageDescription

// Flight: the framework core and the layers that build directly on it.
//
// One package, many products. Everything here shares the module/DI contract
// defined by FlightCore, so a breaking change to that contract breaks all of
// it at once — keeping these targets together makes that a compile error in
// CI rather than a discovery weeks later in whichever adapter was not rebuilt.
//
// Backend drivers deliberately live elsewhere: flight-data carries the
// Postgres and Valkey stories so that nothing here forces a database or cache
// driver onto an application that does not use one.
let package = Package(
    name: "flight",
    platforms: [.macOS(.v15)],
    products: [
        // Configuration: the parser and vocabulary (dependency-free) and the
        // runtime facade over swift-configuration.
        .library(name: "FlightConfigCore", targets: ["FlightConfigCore"]),
        .library(name: "FlightConfig", targets: ["FlightConfig"]),

        // The framework core: container, modules, lifecycle, registration.
        .library(name: "FlightCore", targets: ["FlightCore"]),
        .plugin(name: "FlightRegistrationPlugin", targets: ["FlightRegistrationPlugin"]),

        // Web: routing, middleware, RequestContext, Response, WebSocket/SSE,
        // the ServerTransport seam, and the default HummingbirdCore-backed
        // transport as a peer of any third-party one.
        .library(name: "FlightWeb", targets: ["FlightWeb"]),
        .library(name: "FlightTransport", targets: ["FlightTransport"]),
        .library(name: "FlightWebTesting", targets: ["FlightWebTesting"]),

        // PubSub: Message, the DistributedPubSubAdapter seam, ClusteredPubSub.
        .library(name: "FlightPubSub", targets: ["FlightPubSub"]),
        .library(name: "FlightPubSubTesting", targets: ["FlightPubSubTesting"]),

        // Channels: per-connection lifecycle over PubSub and Web.
        .library(name: "FlightChannels", targets: ["FlightChannels"]),
        .library(name: "FlightChannelsProtocol", targets: ["FlightChannelsProtocol"]),
        .library(name: "FlightChannelsClient", targets: ["FlightChannelsClient"]),
        .library(name: "FlightChannelsTesting", targets: ["FlightChannelsTesting"]),

        // Presence: CRDT-merged "who is here", on top of PubSub and Channels.
        .library(name: "FlightPresence", targets: ["FlightPresence"]),
        .library(name: "FlightPresenceProtocol", targets: ["FlightPresenceProtocol"]),
        .library(name: "FlightPresenceClient", targets: ["FlightPresenceClient"]),

        // Operational endpoints: health, info, metrics.
        .library(name: "FlightActuator", targets: ["FlightActuator"]),

        // Authentication: a resource server. Token *validation* only, with a
        // TokenValidator seam so any issuer can be brought instead.
        .library(name: "FlightSecurityCore", targets: ["FlightSecurityCore"]),
    ],
    dependencies: [
        // Dependency policy: Apple-adjacent and SSWG-blessed only, with one
        // deliberate exception (jwt-kit) noted at its use site.
        .package(url: "https://github.com/apple/swift-configuration.git", from: "1.2.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
        .package(url: "https://github.com/apple/swift-http-types.git", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-service-context.git", from: "1.1.0"),
        .package(url: "https://github.com/apple/swift-distributed-tracing.git", from: "1.1.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.77.0"),
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.6.0"),
        // swift-syntax bumps its major with each Swift release; the open
        // range is the community convention for macro packages.
        .package(url: "https://github.com/swiftlang/swift-syntax.git", "601.0.0"..<"999.0.0"),
        // The default transport wraps HummingbirdCore — explicitly factored
        // as router-on-top-of-core, a public versioned package intended for
        // exactly this use rather than an internal reached into from outside.
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.5.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird-websocket.git", from: "2.2.0"),
        // TLS: used by the transport, and by the web test suite to generate a
        // throwaway self-signed certificate per run — so no private key is
        // ever committed and no fixture can expire.
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.37.0"),
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.19.0"),
        // The one security-critical primitive is delegated: JWTKit is SSWG
        // Graduated and SwiftCrypto-backed. Flight owns orchestration only.
        .package(url: "https://github.com/vapor/jwt-kit.git", from: "5.6.0"),
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.21.0"),
    ],
    targets: [
        // MARK: Configuration

        .target(name: "FlightConfigCore", swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(
            name: "FlightConfig",
            dependencies: [
                "FlightConfigCore",
                .product(name: "Configuration", package: "swift-configuration"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // MARK: Core

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
        // swift-argument-parser deliberately (one positional arg: manifest
        // path). It parses flight.yaml with the *same* parser the runtime
        // uses, so the compile-time key check can never disagree with runtime
        // resolution about what keys a file defines — hence FlightConfigCore
        // rather than FlightConfig: a build tool's dependencies are paid for
        // by every consumer's build, and the check needs the parser, not the
        // provider stack.
        .executableTarget(
            name: "flight-registration-gen",
            dependencies: [
                "FlightConfigCore",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ]
        ),
        .plugin(
            name: "FlightRegistrationPlugin",
            capability: .buildTool(),
            dependencies: ["flight-registration-gen"]
        ),
        .target(
            name: "FlightCore",
            dependencies: [
                "FlightCoreMacrosImpl",
                "FlightConfig",
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .product(name: "Logging", package: "swift-log"),
            ],
            // Strict concurrency is the default under tools 6.x; kept explicit
            // as documentation of intent.
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // MARK: Web

        .macro(
            name: "FlightWebMacrosImpl",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
                .product(name: "SwiftDiagnostics", package: "swift-syntax"),
                .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
            ]
        ),
        .target(
            name: "FlightWeb",
            dependencies: [
                "FlightWebMacrosImpl",
                "FlightCore",
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "ServiceContextModule", package: "swift-service-context"),
                .product(name: "Tracing", package: "swift-distributed-tracing"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // The ONLY target in Flight that knows what the transport wraps.
        // Depends on FlightWeb one-way — routing and middleware never
        // reference this target.
        .target(
            name: "FlightTransport",
            dependencies: [
                "FlightWeb",
                .product(name: "HummingbirdCore", package: "hummingbird"),
                .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket"),
                .product(name: "HummingbirdTLS", package: "hummingbird"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "FlightWebTesting",
            dependencies: [
                "FlightWeb",
                "FlightCore",
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // MARK: PubSub

        .target(
            name: "FlightPubSub",
            dependencies: [
                "FlightCore",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "FlightPubSubTesting",
            dependencies: ["FlightPubSub"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // MARK: Channels

        .target(name: "FlightChannelsProtocol", swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(
            name: "FlightChannels",
            dependencies: [
                "FlightChannelsProtocol", "FlightCore", "FlightPubSub", "FlightWeb",
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "FlightChannelsClient",
            dependencies: [
                "FlightChannelsProtocol",
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "FlightChannelsTesting",
            dependencies: ["FlightChannels", "FlightChannelsClient", "FlightWebTesting"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // MARK: Presence

        .target(
            name: "FlightPresenceProtocol",
            dependencies: ["FlightChannelsProtocol"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "FlightPresence",
            dependencies: [
                "FlightPresenceProtocol", "FlightCore", "FlightPubSub", "FlightChannels",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "FlightPresenceClient",
            dependencies: ["FlightPresenceProtocol", "FlightChannelsClient"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // MARK: Actuator

        .target(
            name: "FlightActuator",
            dependencies: ["FlightWeb", "FlightCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // MARK: Security

        .target(
            name: "FlightSecurityCore",
            dependencies: [
                "FlightCore", "FlightWeb",
                .product(name: "JWTKit", package: "jwt-kit"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // MARK: Tests

        .testTarget(
            name: "FlightConfigTests",
            dependencies: ["FlightConfig"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "FlightCoreTests",
            dependencies: [
                "FlightCore",
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ]
        ),
        // Macro fixture suites are XCTest-based, because assertMacroExpansion
        // ships in SwiftSyntaxMacrosTestSupport as XCTest.
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
        .testTarget(
            name: "FlightRegistrationGenTests",
            dependencies: ["flight-registration-gen"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "FlightWebTests",
            dependencies: [
                "FlightWeb", "FlightWebTesting", "FlightCore",
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ]
        ),
        // Real-socket integration suite: HTTP round-trips, SSE streaming,
        // WebSocket upgrade against a bound FlightTransport.
        .testTarget(
            name: "FlightTransportTests",
            dependencies: [
                "FlightTransport", "FlightWeb", "FlightWebTesting",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ]
        ),
        .testTarget(
            name: "FlightWebMacroTests",
            dependencies: [
                "FlightWebMacrosImpl",
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacroExpansion", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
            ]
        ),
        .testTarget(
            name: "FlightPubSubTests",
            dependencies: [
                "FlightPubSub", "FlightPubSubTesting", "FlightCore",
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .testTarget(
            name: "FlightChannelsTests",
            dependencies: [
                "FlightChannels", "FlightChannelsTesting", "FlightCore",
                "FlightPubSub", "FlightPubSubTesting", "FlightWeb", "FlightWebTesting",
            ]
        ),
        .testTarget(
            name: "FlightChannelsClientTests",
            dependencies: ["FlightChannelsClient", "FlightChannelsTesting", "FlightWebTesting"]
        ),
        .testTarget(
            name: "FlightChannelsE2ETests",
            dependencies: [
                "FlightChannels", "FlightChannelsClient", "FlightCore", "FlightPubSub",
                "FlightWeb", "FlightWebTesting", "FlightTransport",
                .product(name: "HummingbirdWSClient", package: "hummingbird-websocket"),
            ]
        ),
        .testTarget(
            name: "FlightPresenceTests",
            dependencies: [
                "FlightPresence", "FlightPresenceClient", "FlightCore", "FlightPubSub",
                "FlightPubSubTesting", "FlightChannels", "FlightChannelsTesting",
                "FlightWeb", "FlightWebTesting",
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .testTarget(
            name: "FlightActuatorTests",
            dependencies: [
                "FlightActuator", "FlightWeb", "FlightWebTesting", "FlightCore",
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ]
        ),
        .testTarget(
            name: "FlightSecurityCoreTests",
            dependencies: [
                "FlightSecurityCore", "FlightWeb", "FlightWebTesting", "FlightCore",
                .product(name: "JWTKit", package: "jwt-kit"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)

// Documentation tooling only, gated so that consumers never resolve it.
//
//     FLIGHT_BUILD_DOCS=1 swift package generate-documentation
if ProcessInfo.processInfo.environment["FLIGHT_BUILD_DOCS"] != nil {
    package.dependencies.append(
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.3.0")
    )
}
