// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Tick",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "Tick",
            path: "Sources/Tick",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
