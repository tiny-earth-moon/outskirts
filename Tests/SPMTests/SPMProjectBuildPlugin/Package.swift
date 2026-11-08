// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SPMProjectBuildPlugin",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Frontend",
            plugins: ["GenerateCalls"]
        ),
        .executableTarget(
            name: "GeneratorTool"
        ),
        .plugin(
            name: "GenerateCalls",
            capability: .buildTool(),
            dependencies: ["GeneratorTool"]
        ),
    ]
)
