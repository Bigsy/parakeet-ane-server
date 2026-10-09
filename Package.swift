// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "parakeet-ane-server",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "parakeet-ane-server", targets: ["parakeet-ane-server"])
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", exact: "2.27.0"),
        .package(url: "https://github.com/vapor/multipart-kit.git", exact: "4.7.1"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", exact: "1.8.2"),
    ],
    targets: [
        .target(
            name: "ParakeetANE",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "MultipartKit", package: "multipart-kit"),
            ]
        ),
        .executableTarget(
            name: "parakeet-ane-server",
            dependencies: [
                "ParakeetANE",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "ParakeetANETests",
            dependencies: [
                "ParakeetANE",
                .product(name: "HummingbirdTesting", package: "hummingbird"),
            ]
        ),
    ]
)
