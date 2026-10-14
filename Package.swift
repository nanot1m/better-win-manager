// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BetterWM",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "BetterWM",
            path: "Sources/BetterWM",
            linkerSettings: [.linkedFramework("Cocoa"), .linkedFramework("ApplicationServices")]
        )
    ]
)
