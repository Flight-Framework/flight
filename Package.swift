// swift-tools-version: 6.1
// Flight Web — HTTP request lifecycle for Flight: routing, middleware,
// RequestContext, and the ServerTransport seam (flight-web-design.md).
import PackageDescription
import CompilerPluginSupport

let package = Package(
    name: "flight-web",
    platforms: [
        // macOS 15 for Synchronization.Mutex, same floor as flight-core.
        .macOS(.v15)
    ],
    products: [
        // The framework: routing, middleware, RequestContext, Response,
        // WebSocket/SSE surface, ServerTransport protocol, FlightWebModule.
        .library(name: "FlightWeb", targets: ["FlightWeb"]),
        // The default transport (§5.2): wraps HummingbirdCore — a mature,
        // versioned low-level HTTP transport — rather than hand-rolling
        // byte-level HTTP (§10: commodity infrastructure). A peer of any
        // third-party transport.
        .library(name: "FlightTransport", targets: ["FlightTransport"]),
        // Test support (§7): TestContainer, RequestContext.mock, TestClient,
        // InMemoryTransport, in-memory WebSocket pairs.
        .library(name: "FlightWebTesting", targets: ["FlightWebTesting"]),
    ],
    dependencies: [
        .package(path: "../../Core/flight-core"),
        // Dependency policy follows Flight Core §9: Apple-adjacent,
        // SSWG-blessed only.
        .package(url: "https://github.com/apple/swift-http-types.git", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
        .package(url: "https://github.com/apple/swift-service-context.git", from: "1.1.0"),
        .package(url: "https://github.com/apple/swift-distributed-tracing.git", from: "1.1.0"),
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.6.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.77.0"),
        // §5.2: the default transport wraps HummingbirdCore (explicitly
        // factored as router-on-top-of-core; the core is a public, versioned
        // package intended for exactly this use, not an internal reached
        // into from outside).
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.5.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird-websocket.git", from: "2.2.0"),
        .package(url: "https://github.com/swiftlang/swift-syntax.git", "601.0.0"..<"999.0.0"),
    ],
    targets: [
        .target(
            name: "FlightWeb",
            dependencies: [
                "FlightWebMacrosImpl",
                .product(name: "FlightCore", package: "flight-core"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "ServiceContextModule", package: "swift-service-context"),
                .product(name: "Tracing", package: "swift-distributed-tracing"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // The default ServerTransport (§5.2): wraps HummingbirdCore. The
        // ONLY target in all of Flight that knows what the transport wraps
        // (§5.6); depends on FlightWeb one-way — routing/middleware never
        // reference this target (§1.2).
        .target(
            name: "FlightTransport",
            dependencies: [
                "FlightWeb",
                .product(name: "HummingbirdCore", package: "hummingbird"),
                .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket"),
                .product(name: "NIOCore", package: "swift-nio"),
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
                .product(name: "FlightCore", package: "flight-core"),
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
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
        .testTarget(
            name: "FlightWebTests",
            dependencies: [
                "FlightWeb",
                "FlightWebTesting",
                .product(name: "FlightCore", package: "flight-core"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ]
        ),
        // Real-socket integration suite: HTTP round-trips, SSE streaming,
        // WebSocket upgrade against a bound FlightTransport.
        .testTarget(
            name: "FlightTransportTests",
            dependencies: [
                "FlightTransport",
                "FlightWeb",
                "FlightWebTesting",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ]
        ),
        // Macro fixture suite — XCTest, because assertMacroExpansion ships
        // XCTest-based (same shape as FlightCoreMacroTests).
        .testTarget(
            name: "FlightWebMacroTests",
            dependencies: [
                "FlightWebMacrosImpl",
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacroExpansion", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
            ]
        ),
    ]
)
