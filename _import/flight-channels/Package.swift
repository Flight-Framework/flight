// swift-tools-version: 6.1
// Flight Channels — the stateful protocol layer between a raw WebSocket and
// topic-based messaging: join/leave, message routing to per-topic handlers,
// replies, heartbeats, and reconnection.
import PackageDescription

let package = Package(
    name: "flight-channels",
    platforms: [
        // macOS 15 for Synchronization.Mutex in the server targets, same
        // floor as flight-core. The client targets (which deliberately avoid
        // Synchronization — actors only) would run at iOS 17, but SwiftPM
        // platforms are package-wide and the server targets now reach
        // swift-configuration through FlightCore, whose floor is iOS 18.
        // Splitting the client targets into their own package is what would
        // buy that year back, if a consumer ever needs it.
        .macOS(.v15),
        .iOS(.v18),
    ],
    products: [
        // The server: Channel protocol, Socket, ChannelRouter,
        // ChannelBroadcaster, ChannelSocketHandler, FlightChannelsModule.
        .library(name: "FlightChannels", targets: ["FlightChannels"]),
        // The wire protocol on its own: Envelope, JSONValue, reserved
        // events. Shared by server and Swift client; importable by an app's
        // shared message-type module without dragging in either side.
        .library(name: "FlightChannelsProtocol", targets: ["FlightChannelsProtocol"]),
        // The Swift reference client: ChannelClient, transport seam,
        // reconnect-with-backoff-and-rejoin. Depends only on the protocol
        // target and Foundation.
        .library(name: "FlightChannelsClient", targets: ["FlightChannelsClient"]),
        // Test support: in-memory client transport wired to Flight Web's
        // in-process upgrade pipeline — full-stack channel tests, no socket.
        .library(name: "FlightChannelsTesting", targets: ["FlightChannelsTesting"]),
    ],
    dependencies: [
        .package(path: "../../Core/flight-core"),
        .package(path: "../../PubSub/flight-pubsub"),
        .package(path: "../../Web/flight-web"),
        // Dependency policy follows Flight Core: Apple-adjacent,
        // SSWG-blessed only.
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
        // E2E tests only: a real WebSocket client against a bound
        // FlightTransport. Already in the dependency graph via flight-web's
        // transport; never a dependency of any shipped library target.
        .package(url: "https://github.com/hummingbird-project/hummingbird-websocket.git", from: "2.2.0"),
    ],
    targets: [
        .target(
            name: "FlightChannelsProtocol",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "FlightChannels",
            dependencies: [
                "FlightChannelsProtocol",
                .product(name: "FlightCore", package: "flight-core"),
                .product(name: "FlightPubSub", package: "flight-pubsub"),
                .product(name: "FlightWeb", package: "flight-web"),
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
            dependencies: [
                "FlightChannels",
                "FlightChannelsClient",
                .product(name: "FlightWebTesting", package: "flight-web"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "FlightChannelsTests",
            dependencies: [
                "FlightChannels",
                "FlightChannelsTesting",
                .product(name: "FlightCore", package: "flight-core"),
                .product(name: "FlightPubSub", package: "flight-pubsub"),
                .product(name: "FlightPubSubTesting", package: "flight-pubsub"),
                .product(name: "FlightWeb", package: "flight-web"),
                .product(name: "FlightWebTesting", package: "flight-web"),
            ]
        ),
        .testTarget(
            name: "FlightChannelsClientTests",
            dependencies: [
                "FlightChannelsClient",
                "FlightChannelsTesting",
                .product(name: "FlightWebTesting", package: "flight-web"),
            ]
        ),
        // Real-socket integration suite: the full stack — FlightTransport's
        // 101 handshake and frame layer, the channels handler, PubSub — with
        // the reference client on a real TCP connection.
        .testTarget(
            name: "FlightChannelsE2ETests",
            dependencies: [
                "FlightChannels",
                "FlightChannelsClient",
                .product(name: "FlightCore", package: "flight-core"),
                .product(name: "FlightPubSub", package: "flight-pubsub"),
                .product(name: "FlightWeb", package: "flight-web"),
                .product(name: "FlightWebTesting", package: "flight-web"),
                .product(name: "FlightTransport", package: "flight-web"),
                .product(name: "HummingbirdWSClient", package: "hummingbird-websocket"),
            ]
        ),
    ]
)
