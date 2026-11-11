// swift-tools-version:6.0
import PackageDescription

var dependencies: [Package.Dependency] = [
    .package(url: "https://github.com/apple/swift-system", from: "1.0.0"),
    .package(url: "https://github.com/jpsim/Yams", from: "6.0.0"),
    .package(url: "https://github.com/tadija/AEXML", from: "4.0.0"),
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.0.0"),
    // The fork has no release tag, so it is pinned by revision.
    .package(url: "https://github.com/tiny-earth-moon/swift-index-store", revision: "ed1f232d33b8e03956af0f4206fbd30171a43138"),
    .package(url: "https://github.com/apple/swift-syntax", from: "604.0.0"),
    .package(url: "https://github.com/tiny-earth-moon/swift-filename-matcher", from: "2.0.0"),
]

#if os(macOS)
    dependencies.append(
        .package(
            url: "https://github.com/tuist/xcodeproj",
            from: "9.17.6"
        )
    )
#endif

var frontendDependencies: [PackageDescription.Target.Dependency] = [
    .target(name: "CStdio"),
    .target(name: "Shared"),
    .target(name: "Configuration"),
    .target(name: "Fix"),
    .target(name: "Logger"),
    .target(name: "SourceGraph"),
    .target(name: "Indexer"),
    .target(name: "PeripheryKit"),
    .target(name: "ProjectDrivers"),
    .product(name: "ArgumentParser", package: "swift-argument-parser"),
    .product(name: "FilenameMatcher", package: "swift-filename-matcher"),
    .product(name: "SystemPackage", package: "swift-system"),
]

var projectDriverDependencies: [PackageDescription.Target.Dependency] = [
    .target(name: "Extensions"),
    .target(name: "Configuration"),
    .target(name: "Logger"),
    .target(name: "SourceGraph"),
    .target(name: "Shared"),
    .target(name: "Indexer"),
    .product(name: "IndexStore", package: "swift-index-store"),
    .product(name: "SystemPackage", package: "swift-system"),
]

#if os(macOS)
    frontendDependencies.append(.target(name: "XcodeSupport"))
    projectDriverDependencies.append(.target(name: "XcodeSupport"))
#endif

/// Targets converted to the Swift 6 language mode; the others still build in the Swift 5 mode.
let swift6: [SwiftSetting] = [.swiftLanguageMode(.v6)]

var targets: [PackageDescription.Target] = [
    .executableTarget(
        name: "Frontend",
        dependencies: frontendDependencies,
        swiftSettings: swift6
    ),
    .target(
        name: "Configuration",
        dependencies: [
            .target(name: "Extensions"),
            .target(name: "Shared"),
            .product(name: "Yams", package: "Yams"),
            .product(name: "SystemPackage", package: "swift-system"),
            .product(name: "SwiftSyntax", package: "swift-syntax"),
            .product(name: "SwiftParser", package: "swift-syntax"),
            .product(name: "FilenameMatcher", package: "swift-filename-matcher"),
        ],
        swiftSettings: swift6
    ),
    .target(
        name: "Extensions",
        dependencies: [
            .product(name: "SystemPackage", package: "swift-system"),
            .product(name: "FilenameMatcher", package: "swift-filename-matcher"),
        ],
        swiftSettings: swift6
    ),
    .target(
        name: "Fix",
        dependencies: [
            .target(name: "Extensions"),
            .target(name: "PeripheryKit"),
            .target(name: "Shared"),
            .product(name: "SystemPackage", package: "swift-system"),
        ],
        swiftSettings: swift6
    ),
    .target(name: "CStdio"),
    .target(name: "Logger", dependencies: [.target(name: "CStdio")], swiftSettings: swift6),
    .target(
        name: "PeripheryKit",
        dependencies: [
            .target(name: "Extensions"),
            .target(name: "Configuration"),
            .target(name: "Logger"),
            .target(name: "SourceGraph"),
            .target(name: "Shared"),
            .product(name: "SystemPackage", package: "swift-system"),
            .product(name: "FilenameMatcher", package: "swift-filename-matcher"),
        ],
        swiftSettings: swift6
    ),
    .target(
        name: "Indexer",
        dependencies: [
            .target(name: "SyntaxAnalysis"),
            .target(name: "Configuration"),
            .target(name: "Logger"),
            .target(name: "SourceGraph"),
            .target(name: "Shared"),
            .product(name: "IndexStore", package: "swift-index-store"),
            .product(name: "AEXML", package: "AEXML"),
            .product(name: "SystemPackage", package: "swift-system"),
            .product(name: "FilenameMatcher", package: "swift-filename-matcher"),
        ],
        swiftSettings: swift6
    ),
    .target(
        name: "ProjectDrivers",
        dependencies: projectDriverDependencies,
        swiftSettings: swift6
    ),
    .target(
        name: "SyntaxAnalysis",
        dependencies: [
            .target(name: "SourceGraph"),
            .target(name: "Shared"),
            .product(name: "SwiftSyntax", package: "swift-syntax"),
            .product(name: "SwiftParser", package: "swift-syntax"),
            .product(name: "SwiftIfConfig", package: "swift-syntax"),
            .product(name: "SystemPackage", package: "swift-system"),
        ],
        swiftSettings: swift6
    ),
    .target(
        name: "SourceGraph",
        dependencies: [
            .target(name: "Configuration"),
            .target(name: "Logger"),
            .product(name: "SystemPackage", package: "swift-system"),
            .target(name: "Shared"),
        ],
        swiftSettings: swift6
    ),
    .target(
        name: "Shared",
        dependencies: [
            .target(name: "Extensions"),
            .target(name: "Logger"),
            .product(name: "SystemPackage", package: "swift-system"),
        ],
        swiftSettings: swift6
    ),
    .target(
        name: "TestShared",
        dependencies: [
            .target(name: "PeripheryKit"),
            .target(name: "ProjectDrivers"),
            .target(name: "Configuration"),
        ],
        path: "Tests/Shared"
    ),
    .testTarget(
        name: "OutskirtsTests",
        dependencies: [
            .target(name: "TestShared"),
            .target(name: "PeripheryKit"),
            .target(name: "Fix"),
        ]
    ),
    .testTarget(
        name: "FrontendTests",
        dependencies: [
            .target(name: "TestShared"),
            .target(name: "Frontend"),
            .target(name: "Configuration"),
            .target(name: "PeripheryKit"),
            .target(name: "Shared"),
            .target(name: "Logger"),
            .target(name: "Extensions"),
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
            .product(name: "SystemPackage", package: "swift-system"),
        ]
    ),
    .testTarget(
        name: "SPMTests",
        dependencies: [
            .target(name: "TestShared"),
            .target(name: "PeripheryKit"),
        ],
        exclude: ["SPMProject", "SPMProjectMacOS"]
    ),
    .testTarget(
        name: "AccessibilityTests",
        dependencies: [
            .target(name: "TestShared"),
            .target(name: "PeripheryKit"),
            .target(name: "Configuration"),
        ],
        exclude: ["AccessibilityProject"]
    ),
]

#if os(macOS)
    targets.append(contentsOf: [
        .target(
            name: "XcodeSupport",
            dependencies: [
                .target(name: "Configuration"),
                .target(name: "Logger"),
                .target(name: "SourceGraph"),
                .target(name: "Shared"),
                .product(name: "XcodeProj", package: "XcodeProj"),
                .product(name: "SystemPackage", package: "swift-system"),
            ],
            swiftSettings: swift6
        ),
        .testTarget(
            name: "XcodeTests",
            dependencies: [
                .target(name: "ProjectDrivers"),
                .target(name: "TestShared"),
                .target(name: "PeripheryKit"),
            ],
            exclude: ["UIKitProject", "SwiftUIProject", "SyncedGroupProject"]
        ),
    ])
#endif

let package = Package(
    name: "outskirts",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "outskirts", targets: ["Frontend"]),
        .executable(name: "periphery", targets: ["Frontend"]),
        .library(name: "PeripheryKit", targets: ["PeripheryKit"]),
    ],
    dependencies: dependencies,
    targets: targets,
    swiftLanguageModes: [.v5]
)
