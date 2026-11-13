// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "BoCollector",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "BoCollectorCore", targets: ["BoCollectorCore"]),
        .executable(name: "bo-collect", targets: ["BoCollectCLI"]),
        .executable(name: "BoCollectorApp", targets: ["BoCollectorApp"]),
    ],
    targets: [
        .target(
            name: "BoCollectorCore",
            path: "Sources/BoCollectorCore"
        ),
        .executableTarget(
            name: "BoCollectCLI",
            dependencies: ["BoCollectorCore"],
            path: "Sources/BoCollectCLI"
        ),
        .executableTarget(
            name: "BoCollectorApp",
            dependencies: ["BoCollectorCore"],
            path: "Sources/BoCollectorApp"
        ),
        .testTarget(
            name: "BoCollectorTests",
            dependencies: ["BoCollectorCore"],
            path: "Tests/BoCollectorTests"
        ),
    ]
)
