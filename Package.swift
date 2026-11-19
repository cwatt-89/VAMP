// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "VAMP",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "VAMP",
            path: "Sources/VAMP"
        )
    ]
)
