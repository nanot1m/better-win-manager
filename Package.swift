// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BetterWM",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "BetterWMCore", path: "Sources/BetterWMCore"),
        .executableTarget(
            name: "BetterWM",
            dependencies: ["BetterWMCore"],
            path: "Sources/BetterWM",
            linkerSettings: [.linkedFramework("Cocoa"), .linkedFramework("ApplicationServices"), .linkedFramework("CoreLocation"), .linkedFramework("CoreWLAN"), .linkedFramework("IOKit")]
        ),
        .executableTarget(name: "CoreTests", dependencies: ["BetterWMCore"], path: "Tests/BetterWMCoreTests"),
    ]
)
