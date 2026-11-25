// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ImportedTypeExtension",
    targets: [
        .target(name: "Model"),
        .target(name: "Helpers", dependencies: ["Model"]),
        .testTarget(name: "ClientTests", dependencies: ["Model", "Helpers"]),
    ]
)
