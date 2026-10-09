// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "ParakeetBenchmark", platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: ".."),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7"),
        .package(url: "https://github.com/apple/swift-log.git", exact: "1.16.1"),
    ],
    targets: [.executableTarget(name: "Benchmark", dependencies: [
        .product(name: "ParakeetCore", package: "parakeet-ane-server"),
        .product(name: "FluidAudio", package: "FluidAudio"),
        .product(name: "Logging", package: "swift-log"),
    ])]
)
