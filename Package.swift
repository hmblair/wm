// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "wm",
    platforms: [.macOS("14.4")],
    dependencies: [
        .package(url: "https://github.com/LebJe/TOMLKit.git", from: "0.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "wm",
            dependencies: ["TOMLKit"],
            path: "Sources"
        )
    ]
)
