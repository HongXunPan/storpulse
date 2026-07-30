// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "StorPulseMac",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "StorPulseMacAdapter", targets: ["StorPulseMacAdapter"]),
        .library(name: "StorPulseMacUI", targets: ["StorPulseMacUI"]),
        .executable(name: "storpulse-probe", targets: ["StorPulseProbe"]),
        .executable(name: "storpulse-mac", targets: ["StorPulseMacApp"]),
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
        .target(
            name: "StorPulseFFIBridge",
            linkerSettings: [.linkedLibrary("dl")]
        ),
        .target(
            name: "StorPulseSQLiteBridge",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(
            name: "StorPulseMacUI",
            dependencies: ["StorPulseMacAdapter", "StorPulseFFIBridge", "StorPulseSQLiteBridge"]
        ),
        .executableTarget(
            name: "StorPulseMacApp",
            dependencies: ["StorPulseMacUI"]
        ),
        .testTarget(
            name: "StorPulseMacAdapterTests",
            dependencies: ["StorPulseMacAdapter"]
        ),
        .testTarget(
            name: "StorPulseMacUITests",
            dependencies: ["StorPulseMacUI"]
        ),
    ]
)
