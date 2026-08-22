// swift-tools-version: 6.1
// Flight PubSub — topic-based publish/subscribe: the local core (production),
// the distributed-adapter seam, and the clustered composition
// (flight-pubsub-design.md). Bottom of the Live family; also feeds Flight
// Cloud's multi-node story.
import PackageDescription

let package = Package(
    name: "flight-pubsub",
    platforms: [
        // macOS 15 for Synchronization.Mutex, same floor as flight-core.
        .macOS(.v15)
    ],
    products: [
        // The package: Message, PubSub, LocalPubSub, the
        // DistributedPubSubAdapter seam, ClusteredPubSub, PubSubRelayService,
        // and FlightPubSubModule.
        .library(name: "FlightPubSub", targets: ["FlightPubSub"]),
        // Test support: an in-memory multi-node cluster transport and a
        // recording adapter, for consumers (Channels, Presence, Live) to
        // exercise single-node and multi-node code paths without a network.
        .library(name: "FlightPubSubTesting", targets: ["FlightPubSubTesting"]),
    ],
    dependencies: [
        .package(path: "../../Core/flight-core"),
        // Dependency policy follows Flight Core §9: Apple-adjacent,
        // SSWG-blessed only.
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.6.0"),
        // NOTE: the design doc (§2.2) names swift-async-algorithms'
        // AsyncChannel for per-subscriber delivery. It is deliberately NOT a
        // dependency here — see LocalPubSub.swift for the reasoning: the
        // doc's own API contract (synchronous `subscribe` returning
        // `AsyncStream`, publisher never blocked by a slow subscriber) makes
        // a rendezvous channel either publisher-blocking or decorative.
        // Per-subscriber buffering rides AsyncStream's built-in policies
        // instead. Recorded as a design delta in README.md.
    ],
    targets: [
        .target(
            name: "FlightPubSub",
            dependencies: [
                .product(name: "FlightCore", package: "flight-core"),
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
        .testTarget(
            name: "FlightPubSubTests",
            dependencies: [
                "FlightPubSub",
                "FlightPubSubTesting",
                .product(name: "FlightCore", package: "flight-core"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
    ]
)
