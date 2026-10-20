// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MinisRemote",
    platforms: [.iOS(.v16), .macOS(.v14)],
    products: [
        .library(name: "MinisRemote", targets: ["MinisRemote"]),
    ],
    dependencies: [
        .package(url: "https://github.com/orlandos-nl/Citadel.git", exact: "0.9.2"),
        // Citadel asks for ranges, and SwiftPM ignores a dependency's own Package.resolved, so the app build
        // would float its SSH chain (a third-party NIO SSH fork among it). Pinned here; see decisions.md D11.
        .package(url: "https://github.com/Joannis/swift-nio-ssh.git", exact: "0.3.5"),
        .package(url: "https://github.com/attaswift/BigInt.git", exact: "5.7.0"),
        .package(url: "https://github.com/mtynior/ColorizeSwift.git", exact: "1.7.0"),
        // Shared with upstream's own packages, so only a floor: an exact pin would block upstream bumps.
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.104.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", "1.0.0" ..< "2.1.0"),
    ],
    targets: [
        .target(
            name: "MinisRemote",
            dependencies: [
                .product(name: "Citadel", package: "Citadel"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .testTarget(
            name: "MinisRemoteTests",
            dependencies: [
                "MinisRemote",
                .product(name: "Citadel", package: "Citadel"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            resources: [.copy("Golden")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
