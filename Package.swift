// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CFRecorder",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "CFRecorder",
            path: "Sources/CFRecorder",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
