// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CoreConsumer",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../..")],
    targets: [.executableTarget(name: "CoreConsumer", dependencies: [
        .product(name: "ParakeetCore", package: "parakeet-ane-server")
    ])]
)
