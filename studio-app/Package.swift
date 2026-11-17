// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StationStudio",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "StationCore", targets: ["StationCore"]),
        .executable(name: "StationStudio", targets: ["StationStudio"]),
        .executable(name: "StationCoreTestRunner", targets: ["StationCoreTestRunner"]),
    ],
    targets: [
        .target(
            name: "StationCore",
            dependencies: [],
            path: "Sources/StationCore"
        ),
        .executableTarget(
            name: "StationStudio",
            dependencies: ["StationCore"],
            path: "Sources/StationStudio"
        ),
        .executableTarget(
            name: "StationCoreTestRunner",
            dependencies: ["StationCore"],
            path: "Sources/StationCoreTestRunner"
        ),
    ]
)
