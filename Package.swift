// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "parakeet-ane-server",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ParakeetCore", targets: ["ParakeetCore"]),
        .executable(name: "parakeet-ane-server", targets: ["parakeet-ane-server"])
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", exact: "2.27.0"),
        .package(url: "https://github.com/vapor/multipart-kit.git", exact: "4.7.1"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", exact: "1.8.2"),
        .package(url: "https://github.com/apple/swift-log.git", exact: "1.16.1"),
    ],
    targets: [
        .target(name: "ParakeetCore", dependencies: [
            .product(name: "FluidAudio", package: "FluidAudio"),
        ]),
        .testTarget(name: "ParakeetCoreTests", dependencies: ["ParakeetCore"]),
        .target(
            name: "ParakeetANE",
            dependencies: [
                "ParakeetCore",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "MultipartKit", package: "multipart-kit"),
            ]
        ),
        .executableTarget(
            name: "parakeet-ane-server",
            dependencies: [
                "ParakeetANE",
                "ParakeetCore",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "ParakeetANETests",
            dependencies: [
                "ParakeetANE",
                "ParakeetCore",
                .product(name: "HummingbirdTesting", package: "hummingbird"),
            ]
        ),
    ]
)
