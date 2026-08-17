// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MachogsApp",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "MachogsApp", path: "Sources")
    ]
)
