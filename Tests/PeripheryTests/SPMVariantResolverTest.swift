import Configuration
import Foundation
@testable import ProjectDrivers
import Shared
import SystemPackage
import XCTest

final class SPMVariantResolverTest: XCTestCase {
    /// Answers `xcrun --sdk <name> --show-sdk-path` for the installed SDKs and fails for the others.
    private final class SDKShell: Shell, @unchecked Sendable {
        let installed: Set<String>
        private(set) var commands: [[String]] = []

        init(installed: Set<String>) {
            self.installed = installed
        }

        func exec(_ args: [String]) throws -> String {
            commands.append(args)
            guard args.count == 4, args[0] == "xcrun", installed.contains(args[2]) else {
                throw PeripheryError.shellCommandFailed(cmd: args, status: 1, output: "SDK \"\(args[2])\" cannot be located")
            }

            return "/SDKs/\(args[2]).sdk\n"
        }
    }

    private var warnings: [String] = []
    private let macOSAndiOS = [
        PackageDescription.Platform(name: "macos", version: "15.0"),
        PackageDescription.Platform(name: "ios", version: "18.0"),
    ]

    func testAutoBuildsEveryDeclaredPlatformWithItsSDK() throws {
        let variants = try resolver(installed: ["macosx", "iphonesimulator"]).resolve(.auto, platforms: macOSAndiOS)

        XCTAssertEqual(variants.map(\.name), ["arm64-apple-macosx15.0", "arm64-apple-ios18.0-simulator"])
        XCTAssertEqual(Array(variants[1].arguments.prefix(4)), ["--triple", "arm64-apple-ios18.0-simulator", "--sdk", "/SDKs/iphonesimulator.sdk"])
        XCTAssertEqual(variants[1].arguments.suffix(2).first, "--scratch-path")
        XCTAssertEqual(variants[1].arguments.last, variants[1].scratchPath?.string)
        XCTAssertEqual(warnings, [])
    }

    func testAutoSkipsAPlatformWhoseSDKIsMissingWithAWarning() throws {
        let variants = try resolver(installed: ["macosx"]).resolve(.auto, platforms: macOSAndiOS)

        XCTAssertEqual(variants.map(\.name), ["arm64-apple-macosx15.0"])
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings.first?.hasPrefix("Skipping the variant 'arm64-apple-ios18.0-simulator': the SDK 'iphonesimulator' is not installed.") == true, "\(warnings)")
    }

    func testAutoBuildsTheHostWhenNoPlatformIsDeclaredOrOnLinux() throws {
        let host = SPMBuildVariant(name: "host", arguments: [], scratchPath: nil)

        XCTAssertEqual(try resolver(installed: ["macosx"]).resolve(.auto, platforms: nil), [host])
        XCTAssertEqual(try resolver(installed: [], isMacOS: false).resolve(.auto, platforms: macOSAndiOS), [host])
        XCTAssertEqual(warnings, [])
    }

    func testAutoSkipsPlatformsWithoutASimulatorBuildWithAWarning() {
        let platforms = [PackageDescription.Platform(name: "maccatalyst", version: "17.0"), PackageDescription.Platform(name: "visionos", version: "2.0")]

        XCTAssertEqual(resolver(installed: []).platformVariants(for: platforms).map(\.triple), ["arm64-apple-xros2.0-simulator"])
        // A warning makes the variant skipped, which `fix --rule unused` refuses.
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings.first?.hasPrefix("Skipping the declared platform 'maccatalyst'") == true, "\(warnings)")
    }

    func testExplicitVariantsKeepTheirSDKAndConfiguration() throws {
        let variants = try resolver(installed: ["macosx", "iphoneos"]).resolve(.explicit([
            BuildVariant(triple: "arm64-apple-macosx15.0", configuration: "release"),
            BuildVariant(triple: "arm64-apple-ios18.0", sdk: "/Custom/iPhoneOS.sdk"),
        ]), platforms: nil)

        XCTAssertEqual(Array(variants[0].arguments.prefix(6)), ["--triple", "arm64-apple-macosx15.0", "--sdk", "/SDKs/macosx.sdk", "-c", "release"])
        XCTAssertEqual(Array(variants[1].arguments.prefix(4)), ["--triple", "arm64-apple-ios18.0", "--sdk", "/Custom/iPhoneOS.sdk"])
    }

    func testExplicitVariantWithAnUnknownSDKIsSkippedAndNoneLeftIsAnError() throws {
        let resolver = resolver(installed: ["macosx"])
        let unknown = BuildVariant(triple: "arm64-apple-ios18.0-simulator", sdk: "nosuchsdk")

        let variants = try resolver.resolve(.explicit([BuildVariant(triple: "arm64-apple-macosx15.0"), unknown]), platforms: nil)
        XCTAssertEqual(variants.map(\.name), ["arm64-apple-macosx15.0"])
        XCTAssertTrue(warnings.first?.contains("the SDK 'nosuchsdk' is not installed") == true, "\(warnings)")

        XCTAssertThrowsError(try resolver.resolve(.explicit([unknown]), platforms: nil)) { error in
            XCTAssertTrue("\(error)".contains("None of the variants can be built"), "\(error)")
        }
    }

    func testEachVariantHasItsOwnScratchPathInTheCache() throws {
        let cache = FilePath("/cache")
        let variants = try resolver(installed: ["macosx", "iphonesimulator"], cacheDirectory: cache).resolve(.auto, platforms: macOSAndiOS)
        let scratchPaths = variants.compactMap(\.scratchPath)

        XCTAssertEqual(Set(scratchPaths).count, 2)
        for path in scratchPaths {
            XCTAssertEqual(path.removingLastComponent(), cache)
            XCTAssertTrue(path.lastComponent?.string.hasPrefix(CacheManager.packageBuildPrefix) == true, path.string)
        }

        let other = try resolver(installed: ["macosx", "iphonesimulator"], buildArguments: ["-Xswiftc", "-DFLAG"], cacheDirectory: cache)
            .resolve(.auto, platforms: macOSAndiOS)
        XCTAssertTrue(Set(other.compactMap(\.scratchPath)).isDisjoint(with: scratchPaths), "the build arguments are part of the key")
    }

    func testBuildArgumentsSettingTheTripleOrScratchPathAreRejected() {
        for arguments in [["--triple", "x86_64-apple-macosx"], ["--scratch-path=/tmp/x"], ["--sdk", "/SDK"]] {
            XCTAssertThrowsError(try resolver(installed: ["macosx"], buildArguments: arguments).resolve(.auto, platforms: macOSAndiOS), "\(arguments)")
        }
        XCTAssertNoThrow(try resolver(installed: ["macosx"], buildArguments: ["--triple", "x"]).resolve(.default, platforms: nil))
    }

    func testSDKNameOfATriple() {
        XCTAssertEqual(SPMVariantResolver.sdkName(forTriple: "arm64-apple-macosx15.0"), "macosx")
        XCTAssertEqual(SPMVariantResolver.sdkName(forTriple: "arm64-apple-ios18.0-simulator"), "iphonesimulator")
        XCTAssertEqual(SPMVariantResolver.sdkName(forTriple: "arm64-apple-ios18.0"), "iphoneos")
        XCTAssertEqual(SPMVariantResolver.sdkName(forTriple: "arm64-apple-ios17.0-macabi"), "macosx")
        XCTAssertEqual(SPMVariantResolver.sdkName(forTriple: "arm64-apple-tvos18.0-simulator"), "appletvsimulator")
        XCTAssertEqual(SPMVariantResolver.sdkName(forTriple: "arm64-apple-watchos11.0"), "watchos")
        XCTAssertEqual(SPMVariantResolver.sdkName(forTriple: "arm64-apple-xros2.0-simulator"), "xrsimulator")
        XCTAssertNil(SPMVariantResolver.sdkName(forTriple: "x86_64-unknown-linux-gnu"))
    }

    // MARK: - Private

    private func resolver(
        installed: Set<String>,
        isMacOS: Bool = true,
        buildArguments: [String] = [],
        cacheDirectory: FilePath = "/cache"
    ) -> SPMVariantResolver {
        var resolver = SPMVariantResolver(
            shell: SDKShell(installed: installed),
            warn: { [unowned self] in warnings.append($0) },
            projectPath: "/project",
            buildArguments: buildArguments
        )
        resolver.isMacOS = isMacOS
        resolver.hostArchitecture = "arm64"
        resolver.cacheDirectory = cacheDirectory
        return resolver
    }
}
