// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TestOnlyProject",
    targets: [
        .executableTarget(name: "App"),
        .testTarget(name: "AppTests", dependencies: ["App"]),
    ]
)
