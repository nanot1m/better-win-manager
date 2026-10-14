// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BetterWM",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "SkyLightBridge", path: "Sources/SkyLightBridge"),
        .executableTarget(
            name: "BetterWM",
            dependencies: ["SkyLightBridge"],
            path: "Sources/BetterWM",
            linkerSettings: [.linkedFramework("Cocoa"), .linkedFramework("ApplicationServices")]
        ),
    ]
)
