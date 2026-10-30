// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LogicCheck",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/SideStore/RemoteAnisette.git", revision: "50f864489da969492d79dca41d8cc2cd1dade86e")
    ],
    targets: [
        .executableTarget(
            name: "LogicCheck",
            dependencies: [
                .product(name: "RemoteAnisette", package: "RemoteAnisette")
            ],
            path: "Sources/LogicCheck"
        )
    ]
)
