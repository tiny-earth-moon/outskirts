// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "MultiModuleAccessibility",
    targets: [
        .target(name: "LayerA"),
        .target(name: "LayerB", dependencies: ["LayerA"]),
        .target(name: "LayerC", dependencies: ["LayerA", "LayerB"]),
        .target(name: "Facade", dependencies: ["LayerA"]),
        .testTarget(name: "FacadeClientTests", dependencies: ["Facade"]),
        .testTarget(name: "LayerBClientTests", dependencies: ["LayerB"]),
        .testTarget(name: "LayerCClientTests", dependencies: ["LayerC"]),
    ]
)
