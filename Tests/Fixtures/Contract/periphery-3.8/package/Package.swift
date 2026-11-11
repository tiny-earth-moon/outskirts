// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Contract",
    targets: [
        .target(name: "Fixture"),
        .executableTarget(name: "App", dependencies: ["Fixture"]),
    ]
)
