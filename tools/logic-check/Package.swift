// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LogicCheck",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "LogicCheck",
            path: "Sources/LogicCheck"
        )
    ]
)
