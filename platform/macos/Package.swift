// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "StorPulseMac",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "StorPulseMacAdapter", targets: ["StorPulseMacAdapter"]),
        .executable(name: "storpulse-probe", targets: ["StorPulseProbe"]),
    ],
    targets: [
        .target(
            name: "StorPulseMacAdapter",
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .executableTarget(
            name: "StorPulseProbe",
            dependencies: ["StorPulseMacAdapter"]
        ),
        .testTarget(
            name: "StorPulseMacAdapterTests",
            dependencies: ["StorPulseMacAdapter"]
        ),
    ]
)
