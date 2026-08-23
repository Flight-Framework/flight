// swift-tools-version: 6.1
// Flight Presence — "who is currently connected to this topic", kept correct
// across every node in a cluster: CRDT-merged distributed state over Flight
// PubSub, per-connection lifecycle over Flight Channels, initial-state-then-
// diffs to clients. Top of the real-time family.
import PackageDescription

let package = Package(
    name: "flight-presence",
    platforms: [
        // macOS 15 for Synchronization.Mutex in the server target, same
        // floor as flight-core. iOS 18 matches FlightChannelsClient's floor
        // so a native app can consume the presence helper; both rose from
        // iOS 17 when Flight Config moved onto swift-configuration.
        .macOS(.v15),
        .iOS(.v18),
    ],
    products: [
        // The server: Presence protocol, PresenceTracker, the membership
        // seam, PresenceService, FlightPresenceModule.
        .library(name: "FlightPresence", targets: ["FlightPresence"]),
        // The wire vocabulary on its own: event names, the
        // state/diff payload shapes, and the pure diff-applying state
        // machine shared by server tests and both client helpers.
        .library(name: "FlightPresenceProtocol", targets: ["FlightPresenceProtocol"]),
        // The Swift client presence helper (design, Channels):
        // applies state/diff messages from a ChannelHandle to a maintained
        // list, so application code never touches raw diff plumbing.
        .library(name: "FlightPresenceClient", targets: ["FlightPresenceClient"]),
    ],
    dependencies: [
        .package(path: "../../Core/flight-core"),
        .package(path: "../../PubSub/flight-pubsub"),
        .package(path: "../../Channels/flight-channels"),
        .package(path: "../../Web/flight-web"),
        // Dependency policy follows Flight Core: Apple-adjacent,
        // SSWG-blessed only.
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.6.0"),
    ],
    targets: [
        .target(
            name: "FlightPresenceProtocol",
            dependencies: [
                .product(name: "FlightChannelsProtocol", package: "flight-channels")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "FlightPresence",
            dependencies: [
                "FlightPresenceProtocol",
                .product(name: "FlightCore", package: "flight-core"),
                .product(name: "FlightPubSub", package: "flight-pubsub"),
                .product(name: "FlightChannels", package: "flight-channels"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "FlightPresenceClient",
            dependencies: [
                "FlightPresenceProtocol",
                .product(name: "FlightChannelsClient", package: "flight-channels"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "FlightPresenceTests",
            dependencies: [
                "FlightPresence",
                "FlightPresenceClient",
                .product(name: "FlightCore", package: "flight-core"),
                .product(name: "FlightPubSub", package: "flight-pubsub"),
                .product(name: "FlightPubSubTesting", package: "flight-pubsub"),
                .product(name: "FlightChannels", package: "flight-channels"),
                .product(name: "FlightChannelsTesting", package: "flight-channels"),
                .product(name: "FlightWeb", package: "flight-web"),
                .product(name: "FlightWebTesting", package: "flight-web"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
    ]
)
