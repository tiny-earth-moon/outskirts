#if os(macOS)
    import Configuration
    import Foundation
    import Logger
    @testable import ProjectDrivers
    import Shared
    import SystemPackage
    import TestShared
    @testable import XcodeSupport
    import XCTest

    final class XcodeProjectVariantsTest: XCTestCase {
        /// Answers `xcodebuild -version`, `xcrun --sdk` for the installed SDKs, `-showBuildSettings` and the builds.
        private final class XcodeShell: Shell, @unchecked Sendable {
            var installedSDKs: Set<String> = ["macosx", "iphonesimulator", "iphoneos"]
            var buildSettings = "[]"
            var failingDestination: String?
            private(set) var commands: [[String]] = []

            var builds: [[String]] {
                commands.filter { $0.contains("build-for-testing") }
            }

            func exec(_ args: [String]) throws -> String {
                commands.append(args)
                if args == ["xcodebuild", "-version"] {
                    return "Xcode 0.0"
                }
                if args.first == "xcrun" {
                    guard installedSDKs.contains(args[2]) else {
                        throw PeripheryError.shellCommandFailed(cmd: args, status: 1, output: "SDK cannot be located")
                    }

                    return "/SDKs/\(args[2]).sdk\n"
                }
                if args.contains("-showBuildSettings") {
                    return buildSettings
                }
                if let failingDestination, args.contains(failingDestination) {
                    throw PeripheryError.shellCommandFailed(cmd: args, status: 65, output: "** BUILD FAILED **")
                }
                return ""
            }
        }

        private final class ProjectStub: XcodeProjectlike {
            let path = FilePath("/tmp/Variants-\(UUID().uuidString)/Sample.xcodeproj")
            let targets: Set<XcodeTarget> = []
            let type = "project"
            var sourceRoot: FilePath {
                path.removingLastComponent()
            }

            func schemes(additionalArguments _: [String]) throws -> Set<String> {
                []
            }
        }

        private let logger = Logger(quiet: true, verbose: false, colorMode: .never)
        private var shell: XcodeShell!
        private var xcodebuild: Xcodebuild!
        private var project: ProjectStub!
        private var warnings: [String] = []

        override func setUp() {
            super.setUp()
            shell = XcodeShell()
            xcodebuild = Xcodebuild(shell: shell, logger: logger, cacheDirectory: TestCacheDirectory.path)
            project = ProjectStub()
            warnings = []
        }

        // MARK: - Driver

        func testDefaultVariantsRunTheSameBuildAsWithoutTheSetting() throws {
            var configuration = Configuration()
            configuration.buildArguments = ["-configuration", "Release", "OTHER_SWIFT_FLAGS=-D A"]

            let driver = makeDriver(configuration)
            try driver.build()

            let derivedDataPath = try xcodebuild.derivedDataPath(for: project, schemes: ["App"], buildArguments: configuration.buildArguments).string
            XCTAssertEqual(shell.commands.filter { $0 != ["xcodebuild", "-version"] }, [[
                "xcodebuild",
                "-project", project.path.string,
                "-scheme", "App",
                "-parallelizeTargets",
                "-derivedDataPath", derivedDataPath,
                "-quiet",
                "build-for-testing",
                "CODE_SIGNING_ALLOWED=NO",
                "ENABLE_BITCODE=NO",
                "DEBUG_INFORMATION_FORMAT=dwarf",
                "COMPILER_INDEX_STORE_ENABLE=YES",
                "INDEX_ENABLE_DATA_STORE=YES",
                "-configuration", "Release",
                "OTHER_SWIFT_FLAGS=-D A",
            ]])
            XCTAssertEqual(driver.builtVariants, [])
        }

        func testExplicitVariantsBuildEachDestinationInItsOwnDerivedData() throws {
            var configuration = Configuration()
            configuration.buildArguments = ["OTHER_SWIFT_FLAGS=-D A"]
            configuration.variants = .explicit([
                BuildVariant(triple: "arm64-apple-macosx15.0"),
                BuildVariant(triple: "arm64-apple-ios18.0-simulator", sdk: "iphonesimulator", configuration: "Release"),
                BuildVariant(triple: "arm64-apple-ios17.0-macabi"),
            ])

            let driver = makeDriver(configuration)
            try driver.build()

            let builds = shell.builds
            XCTAssertEqual(builds.map { Array($0.suffix(from: $0.firstIndex(of: "OTHER_SWIFT_FLAGS=-D A")!)) }, [
                ["OTHER_SWIFT_FLAGS=-D A", "-destination", "generic/platform=macOS"],
                ["OTHER_SWIFT_FLAGS=-D A", "-destination", "generic/platform=iOS Simulator", "-sdk", "iphonesimulator", "-configuration", "Release"],
                ["OTHER_SWIFT_FLAGS=-D A", "-destination", "generic/platform=macOS,variant=Mac Catalyst"],
            ])
            let derivedDataPaths = builds.map { $0[$0.firstIndex(of: "-derivedDataPath")! + 1] }
            let defaultPath = try xcodebuild.derivedDataPath(for: project, schemes: ["App"], buildArguments: configuration.buildArguments).string
            XCTAssertEqual(Set(derivedDataPaths).count, 3, "\(derivedDataPaths)")
            XCTAssertFalse(derivedDataPaths.contains(defaultPath))
            XCTAssertEqual(driver.builtVariants, [
                "arm64-apple-macosx15.0",
                "arm64-apple-ios18.0-simulator,sdk=iphonesimulator,configuration=Release",
                "arm64-apple-ios17.0-macabi",
            ])
        }

        func testAutoBuildsThePlatformsTheSchemesSupport() throws {
            shell.buildSettings = """
            warning: unrelated
            [
              {"target": "App", "buildSettings": {"SUPPORTED_PLATFORMS": "iphoneos iphonesimulator"}},
              {"target": "Kit", "buildSettings": {"SUPPORTED_PLATFORMS": "macosx iphonesimulator driverkit"}}
            ]
            """
            var configuration = Configuration()
            configuration.variants = .auto

            let driver = makeDriver(configuration)
            try driver.build()

            let destinations = shell.builds.map { $0[$0.firstIndex(of: "-destination")! + 1] }
            XCTAssertEqual(destinations, ["generic/platform=macOS", "generic/platform=iOS Simulator"])
            XCTAssertEqual(driver.builtVariants.count, 2)
            XCTAssertTrue(driver.builtVariants[1].hasSuffix("-apple-ios-simulator"), "\(driver.builtVariants)")
            XCTAssertEqual(driver.skippedVariants.count, 1)
            XCTAssertTrue(driver.skippedVariants.first?.hasPrefix("Skipping the supported platform 'driverkit'") == true, "\(driver.skippedVariants)")
        }

        func testAutoSkipsMacCatalystWithAWarning() throws {
            shell.buildSettings = """
            [{"target": "App", "buildSettings": {"SUPPORTED_PLATFORMS": "iphoneos iphonesimulator", "SUPPORTS_MACCATALYST": "YES"}}]
            """
            var configuration = Configuration()
            configuration.variants = .auto

            let driver = makeDriver(configuration)
            try driver.build()

            XCTAssertEqual(driver.builtVariants.count, 1)
            XCTAssertEqual(driver.skippedVariants.count, 1)
            XCTAssertTrue(driver.skippedVariants.first?.hasPrefix("Skipping the supported platform 'maccatalyst'") == true, "\(driver.skippedVariants)")
        }

        func testTheFirstFailedBuildStopsTheScanAndNamesTheVariant() throws {
            shell.failingDestination = "generic/platform=iOS Simulator"
            var configuration = Configuration()
            configuration.variants = .explicit([BuildVariant(triple: "arm64-apple-ios18.0-simulator"), BuildVariant(triple: "arm64-apple-macosx15.0")])

            XCTAssertThrowsError(try makeDriver(configuration).build()) { error in
                XCTAssertTrue("\(error)".contains("The build of the variant 'arm64-apple-ios18.0-simulator' failed"), "\(error)")
            }
            XCTAssertEqual(shell.builds.count, 1)
        }

        func testCleanBuildRemovesTheDerivedDataOfEachVariant() throws {
            var configuration = Configuration()
            configuration.cleanBuild = true
            configuration.variants = .explicit([BuildVariant(triple: "arm64-apple-ios18.0-simulator"), BuildVariant(triple: "arm64-apple-macosx15.0")])
            let paths = try [
                ["-destination", "generic/platform=iOS Simulator"],
                ["-destination", "generic/platform=macOS"],
            ].map { try xcodebuild.derivedDataPath(for: project, schemes: ["App"], buildArguments: $0) }
            let leftovers = paths.map { $0.appending("leftover") }
            for (path, leftover) in zip(paths, leftovers) {
                try FileManager.default.createDirectory(atPath: path.string, withIntermediateDirectories: true)
                XCTAssertTrue(FileManager.default.createFile(atPath: leftover.string, contents: Data()))
            }

            try makeDriver(configuration).build()

            // Each folder is removed, then created again and locked for the build of its variant.
            XCTAssertEqual(leftovers.filter(\.exists), [])
        }

        // MARK: - Resolver

        func testAutoSkipsAPlatformWhoseSDKIsMissingAndFallsBackToTheHost() throws {
            shell.installedSDKs = ["macosx"]

            let variants = try resolver().resolve(.auto) { ["macosx", "appletvos", "appletvsimulator"] }

            XCTAssertEqual(variants, [XcodeBuildVariant(name: "arm64-apple-macosx", arguments: ["-destination", "generic/platform=macOS"])])
            XCTAssertEqual(warnings.count, 1)
            XCTAssertTrue(warnings[0].hasPrefix("Skipping the variant 'arm64-apple-tvos-simulator': the SDK 'appletvsimulator' is not installed."), "\(warnings)")

            shell.installedSDKs = []
            warnings = []
            let host = XcodeBuildVariant(name: "host", arguments: [])
            XCTAssertEqual(try resolver().resolve(.auto) { ["watchos", "watchsimulator"] }, [host])
            XCTAssertEqual(warnings.last, "No SDK of the platforms supported by the schemes is installed, building for the host only.")
            XCTAssertEqual(try resolver().resolve(.auto) { [] }, [host])
        }

        func testDefaultReadsNoPlatformAndRunsNoCommand() throws {
            let variants = try resolver().resolve(.default) {
                XCTFail("The supported platforms are read for 'auto' only")
                return []
            }

            XCTAssertEqual(variants, [XcodeBuildVariant(name: "host", arguments: [])])
            XCTAssertEqual(shell.commands, [])
        }

        func testBuildArgumentsThatSetTheDestinationAreRejected() {
            for option in ["-destination", "-sdk", "-arch", "-derivedDataPath"] {
                XCTAssertThrowsError(try resolver(buildArguments: [option, "x"]).resolve(.auto) { [] }) { error in
                    XCTAssertTrue("\(error)".contains("The build argument '\(option)' cannot be combined with '--variants'"), "\(error)")
                }
            }
            let configured = BuildVariants.explicit([BuildVariant(triple: "arm64-apple-macosx15.0", configuration: "Release")])
            XCTAssertThrowsError(try resolver(buildArguments: ["-configuration", "Debug"]).resolve(configured) { [] })
            XCTAssertNoThrow(try resolver(buildArguments: ["-configuration", "Debug"]).resolve(.explicit([BuildVariant(triple: "arm64-apple-macosx15.0")])) { [] })
        }

        func testAVariantWithoutAnApplePlatformIsRejected() {
            XCTAssertThrowsError(try resolver().resolve(.explicit([BuildVariant(triple: "x86_64-unknown-linux-gnu")])) { [] }) { error in
                XCTAssertTrue("\(error)".contains("cannot be built with xcodebuild"), "\(error)")
            }
        }

        func testDestinationOfEachTriple() {
            let expected = [
                "arm64-apple-macosx15.0": "generic/platform=macOS",
                "arm64-apple-ios17.0-macabi": "generic/platform=macOS,variant=Mac Catalyst",
                "arm64-apple-ios18.0": "generic/platform=iOS",
                "arm64-apple-ios18.0-simulator": "generic/platform=iOS Simulator",
                "arm64-apple-tvos18.0-simulator": "generic/platform=tvOS Simulator",
                "arm64-apple-watchos11.0-simulator": "generic/platform=watchOS Simulator",
                "arm64-apple-xros2.0-simulator": "generic/platform=visionOS Simulator",
                "arm64-apple-visionos2.0": "generic/platform=visionOS",
            ]
            for (triple, destination) in expected {
                XCTAssertEqual(XcodeVariantResolver.destination(forTriple: triple), destination, triple)
            }
            XCTAssertNil(XcodeVariantResolver.destination(forTriple: "x86_64-unknown-linux-gnu"))
        }

        func testSupportedPlatformsAreReadFromTheBuildSettings() throws {
            let output = """
            Command line invocation: xcodebuild -showBuildSettings
            [{"target": "A", "buildSettings": {"SUPPORTED_PLATFORMS": "macosx"}}, {"target": "B", "buildSettings": {"SUPPORTED_PLATFORMS": "xrsimulator macosx xros"}}]
            """

            XCTAssertEqual(try Xcodebuild.supportedPlatforms(fromBuildSettings: output), ["macosx", "xrsimulator", "xros"])
            XCTAssertThrowsError(try Xcodebuild.supportedPlatforms(fromBuildSettings: "error: no scheme"))
        }

        // MARK: - Private

        private func makeDriver(_ configuration: Configuration) -> XcodeProjectDriver {
            XcodeProjectDriver(logger: logger, configuration: configuration, xcodebuild: xcodebuild, project: project, schemes: ["App"], shell: shell)
        }

        private func resolver(buildArguments: [String] = []) -> XcodeVariantResolver {
            XcodeVariantResolver(
                shell: shell,
                warn: { [unowned self] in warnings.append($0) },
                buildArguments: buildArguments,
                hostArchitecture: "arm64"
            )
        }
    }
#endif
