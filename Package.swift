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
    traits: [
        // Every optional trait is a DEFAULT trait, and consumers subtract.
        //
        // This is not the shape you would choose freely — opt-in reads better
        // than opt-out. It is forced by SwiftPM 6.2.3: a consumer enabling a
        // NON-default trait on a *versioned* dependency does not cause that
        // trait's gated package dependencies to be resolved, and the build
        // fails with "exhausted attempts to resolve the dependencies graph".
        // Path dependencies resolve correctly, which is why this only shows
        // up once a package is tagged and consumed for real. Default traits
        // resolve correctly either way, so every optional trait is one.
        //
        //     traits: []                  container and lifecycle only, 7 packages
        //     traits: ["Web"]             + HTTP, WebSockets, Channels, Presence
        //     (unspecified)               everything, including Security
        .default(enabledTraits: ["Web", "Security"]),
        .trait(
            name: "Web",
            description: "HTTP, WebSockets, SSE, Channels, Presence, and the actuator."
        ),
        .trait(
            name: "Security",
            description: "OIDC/JWT resource-server authentication.",
            enabledTraits: ["Web"]
        ),
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
                .target(name: "FlightWebMacrosImpl", condition: .when(traits: ["Web"])),
                "FlightCore",
                .product(name: "HTTPTypes", package: "swift-http-types", condition: .when(traits: ["Web"])),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "ServiceContextModule", package: "swift-service-context", condition: .when(traits: ["Web"])),
                .product(name: "Tracing", package: "swift-distributed-tracing", condition: .when(traits: ["Web"])),
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
                .target(name: "FlightWeb", condition: .when(traits: ["Web"])),
                .product(name: "HummingbirdCore", package: "hummingbird", condition: .when(traits: ["Web"])),
                .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket", condition: .when(traits: ["Web"])),
                .product(name: "HummingbirdTLS", package: "hummingbird", condition: .when(traits: ["Web"])),
                .product(name: "NIOCore", package: "swift-nio", condition: .when(traits: ["Web"])),
                .product(name: "NIOSSL", package: "swift-nio-ssl", condition: .when(traits: ["Web"])),
                .product(name: "HTTPTypes", package: "swift-http-types", condition: .when(traits: ["Web"])),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "FlightWebTesting",
            dependencies: [
                .target(name: "FlightWeb", condition: .when(traits: ["Web"])),
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
                "FlightChannelsProtocol", "FlightCore", "FlightPubSub", .target(name: "FlightWeb", condition: .when(traits: ["Web"])),
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
            dependencies: [.target(name: "FlightChannels", condition: .when(traits: ["Web"])), "FlightChannelsClient", .target(name: "FlightWebTesting", condition: .when(traits: ["Web"]))],
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
                "FlightPresenceProtocol", "FlightCore", "FlightPubSub", .target(name: "FlightChannels", condition: .when(traits: ["Web"])),
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
            dependencies: [.target(name: "FlightWeb", condition: .when(traits: ["Web"])), "FlightCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // MARK: Security

        .target(
            name: "FlightSecurityCore",
            dependencies: [
                "FlightCore", .target(name: "FlightWeb", condition: .when(traits: ["Web"])),
                .product(name: "JWTKit", package: "jwt-kit", condition: .when(traits: ["Security"])),
                .product(name: "AsyncHTTPClient", package: "async-http-client", condition: .when(traits: ["Security"])),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .product(name: "HTTPTypes", package: "swift-http-types", condition: .when(traits: ["Web"])),
                .product(name: "NIOCore", package: "swift-nio", condition: .when(traits: ["Web"])),
                .product(name: "NIOFoundationCompat", package: "swift-nio", condition: .when(traits: ["Web"])),
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
        // Macro fixture suites use SwiftSyntaxMacrosGenericTestSupport, not
        // SwiftSyntaxMacrosTestSupport: the latter reports through XCTFail and
        // would force these suites onto XCTest. The generic variant hands
        // failures back, so they record as swift-testing issues like every
        // other suite here. See Tests/*/SwiftTestingBridge.swift.
        .testTarget(
            name: "FlightCoreMacroTests",
            dependencies: [
                "FlightCoreMacrosImpl",
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                // MacroSpec — carries declared conformances into assertMacroExpansion.
                .product(name: "SwiftSyntaxMacroExpansion", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacrosGenericTestSupport", package: "swift-syntax"),
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
                .target(name: "FlightWeb", condition: .when(traits: ["Web"])), .target(name: "FlightWebTesting", condition: .when(traits: ["Web"])), "FlightCore",
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ]
        ),
        // Real-socket integration suite: HTTP round-trips, SSE streaming,
        // WebSocket upgrade against a bound FlightTransport.
        .testTarget(
            name: "FlightTransportTests",
            dependencies: [
                .target(name: "FlightTransport", condition: .when(traits: ["Web"])), .target(name: "FlightWeb", condition: .when(traits: ["Web"])), .target(name: "FlightWebTesting", condition: .when(traits: ["Web"])),
                .product(name: "NIOCore", package: "swift-nio", condition: .when(traits: ["Web"])),
                .product(name: "NIOPosix", package: "swift-nio", condition: .when(traits: ["Web"])),
                .product(name: "NIOHTTP1", package: "swift-nio", condition: .when(traits: ["Web"])),
                .product(name: "NIOWebSocket", package: "swift-nio", condition: .when(traits: ["Web"])),
                .product(name: "NIOSSL", package: "swift-nio-ssl", condition: .when(traits: ["Web"])),
                .product(name: "X509", package: "swift-certificates", condition: .when(traits: ["Web"])),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ]
        ),
        .testTarget(
            name: "FlightWebMacroTests",
            dependencies: [
                .target(name: "FlightWebMacrosImpl", condition: .when(traits: ["Web"])),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacroExpansion", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacrosGenericTestSupport", package: "swift-syntax"),
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
                .target(name: "FlightChannels", condition: .when(traits: ["Web"])), .target(name: "FlightChannelsTesting", condition: .when(traits: ["Web"])), "FlightCore",
                "FlightPubSub", "FlightPubSubTesting", .target(name: "FlightWeb", condition: .when(traits: ["Web"])), .target(name: "FlightWebTesting", condition: .when(traits: ["Web"])),
            ]
        ),
        .testTarget(
            name: "FlightChannelsClientTests",
            dependencies: ["FlightChannelsClient", .target(name: "FlightChannelsTesting", condition: .when(traits: ["Web"])), .target(name: "FlightWebTesting", condition: .when(traits: ["Web"]))]
        ),
        .testTarget(
            name: "FlightChannelsE2ETests",
            dependencies: [
                .target(name: "FlightChannels", condition: .when(traits: ["Web"])), "FlightChannelsClient", "FlightCore", "FlightPubSub",
                .target(name: "FlightWeb", condition: .when(traits: ["Web"])), .target(name: "FlightWebTesting", condition: .when(traits: ["Web"])), .target(name: "FlightTransport", condition: .when(traits: ["Web"])),
                .product(name: "HummingbirdWSClient", package: "hummingbird-websocket", condition: .when(traits: ["Web"])),
            ]
        ),
        .testTarget(
            name: "FlightPresenceTests",
            dependencies: [
                .target(name: "FlightPresence", condition: .when(traits: ["Web"])), "FlightPresenceClient", "FlightCore", "FlightPubSub",
                "FlightPubSubTesting", .target(name: "FlightChannels", condition: .when(traits: ["Web"])), .target(name: "FlightChannelsTesting", condition: .when(traits: ["Web"])),
                .target(name: "FlightWeb", condition: .when(traits: ["Web"])), .target(name: "FlightWebTesting", condition: .when(traits: ["Web"])),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .testTarget(
            name: "FlightActuatorTests",
            dependencies: [
                .target(name: "FlightActuator", condition: .when(traits: ["Web"])), .target(name: "FlightWeb", condition: .when(traits: ["Web"])), .target(name: "FlightWebTesting", condition: .when(traits: ["Web"])), "FlightCore",
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ]
        ),
        .testTarget(
            name: "FlightSecurityCoreTests",
            dependencies: [
                .target(name: "FlightSecurityCore", condition: .when(traits: ["Security"])), .target(name: "FlightWeb", condition: .when(traits: ["Web"])), .target(name: "FlightWebTesting", condition: .when(traits: ["Web"])), "FlightCore",
                .product(name: "JWTKit", package: "jwt-kit", condition: .when(traits: ["Security"])),
                .product(name: "HTTPTypes", package: "swift-http-types", condition: .when(traits: ["Web"])),
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

// Strict warnings, opt-in and scoped to Flight's own targets.
//
// `swift build -Xswiftc -warnings-as-errors` cannot be used for this: it
// applies to every module in the build, dependencies included, so a warning
// in third-party code that a newer compiler has already fixed fails the
// build. This setting reaches only the targets declared above.
//
//     FLIGHT_STRICT_WARNINGS=1 swift build --enable-all-traits
if ProcessInfo.processInfo.environment["FLIGHT_STRICT_WARNINGS"] != nil {
    // Plugin targets reject build settings outright.
    for target in package.targets where target.type != .plugin {
        var settings = target.swiftSettings ?? []
        settings.append(.treatAllWarnings(as: .error))
        target.swiftSettings = settings
    }
}
