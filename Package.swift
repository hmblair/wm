// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "focus-follows-mouse",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "focus-follows-mouse", path: "Sources")
    ]
)
