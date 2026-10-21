// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Keylog",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "KeylogCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "Keylog",
            dependencies: ["KeylogCore"]
        ),
        .testTarget(
            name: "KeylogCoreTests",
            dependencies: ["KeylogCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
