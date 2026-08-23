// swift-tools-version: 6.1
// Flight Security Core — federated authentication for Flight: token
// validation (JWTKit-backed), Principal plumbing, and the authentication
// enforcement seam.
import PackageDescription

let package = Package(
    name: "flight-security-core",
    platforms: [
        // macOS 15 for Synchronization.Mutex, same floor as flight-core.
        .macOS(.v15)
    ],
    products: [
        // Principal, TokenValidator (+ the generic OIDC implementation),
        // authentication middleware, requireAuthentication, module wiring.
        .library(name: "FlightSecurityCore", targets: ["FlightSecurityCore"])
    ],
    dependencies: [
        .package(path: "../../../Core/flight-core"),
        .package(path: "../../../Web/flight-web"),
        // The one security-critical primitive is delegated:
        // JWTKit is SSWG Graduated and SwiftCrypto-backed. Flight owns
        // orchestration only.
        .package(url: "https://github.com/vapor/jwt-kit.git", from: "5.6.0"),
        // JWKS fetching. SSWG-graduated client; already in the
        // Flight dependency graph transitively via hummingbird.
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.21.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.6.0"),
        .package(url: "https://github.com/apple/swift-http-types.git", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.77.0"),
    ],
    targets: [
        .target(
            name: "FlightSecurityCore",
            dependencies: [
                .product(name: "FlightCore", package: "flight-core"),
                .product(name: "FlightWeb", package: "flight-web"),
                .product(name: "JWTKit", package: "jwt-kit"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
            ],
            swiftSettings: [
                // Strict concurrency is the default under tools 6.x; kept
                // explicit as documentation of intent, matching flight-core.
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "FlightSecurityCoreTests",
            dependencies: [
                "FlightSecurityCore",
                .product(name: "FlightWeb", package: "flight-web"),
                .product(name: "FlightWebTesting", package: "flight-web"),
                .product(name: "FlightCore", package: "flight-core"),
                .product(name: "JWTKit", package: "jwt-kit"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
