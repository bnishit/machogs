// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MachogsApp",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "MachogsApp", targets: ["MachogsApp"])
    ],
    targets: [
        .target(name: "MachogsCore", path: "Sources/Core"),
        .executableTarget(
            name: "MachogsApp",
            dependencies: ["MachogsCore"],
            path: "Sources/App"
        ),
        .testTarget(
            name: "MachogsCoreTests",
            dependencies: ["MachogsCore"],
            path: "Tests/MachogsCoreTests"
        )
    ]
)
