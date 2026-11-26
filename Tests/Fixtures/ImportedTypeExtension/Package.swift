// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ImportedTypeExtension",
    targets: [
        .target(name: "Model"),
        .target(name: "Helpers", dependencies: ["Model"]),
        .target(name: "Helpers2", dependencies: ["Model"]),
        .target(name: "ChainHelpers", dependencies: ["Model"]),
        .testTarget(name: "ClientTests", dependencies: ["Model", "Helpers"]),
        .testTarget(name: "Helpers2ClientTests", dependencies: ["Model", "Helpers2"]),
        .testTarget(name: "ChainClientTests", dependencies: ["ChainHelpers"]),
    ]
)
