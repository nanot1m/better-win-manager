// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BetterWM",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "SkyLightBridge", path: "Sources/SkyLightBridge"),
        .target(name: "BetterWMCore", path: "Sources/BetterWMCore"),
        .executableTarget(
            name: "BetterWM",
            dependencies: ["SkyLightBridge", "BetterWMCore"],
            path: "Sources/BetterWM",
            linkerSettings: [.linkedFramework("Cocoa"), .linkedFramework("ApplicationServices")]
        ),
        .executableTarget(name: "CoreTests", dependencies: ["BetterWMCore"], path: "Tests/BetterWMCoreTests"),
    ]
)
