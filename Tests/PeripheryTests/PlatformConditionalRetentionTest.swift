import Configuration
import Logger
import Shared
@testable import SourceGraph
import SystemPackage
import XCTest

final class PlatformConditionalRetentionTest: XCTestCase {
    private let macOS = IndexVariant(triple: "arm64-apple-macosx15.0", isOptimized: false)
    private let macOSRelease = IndexVariant(triple: "arm64-apple-macosx15.0", isOptimized: true)
    private let iOSSimulator = IndexVariant(triple: "arm64-apple-ios18.0-simulator", isOptimized: false)
    private let iOS = IndexVariant(triple: "arm64-apple-ios18.0", isOptimized: false)
    private let catalyst = IndexVariant(triple: "arm64-apple-ios18.0-macabi", isOptimized: false)
    private let watchOS = IndexVariant(triple: "arm64_32-apple-watchos11.0", isOptimized: false)
    private let linux = IndexVariant(triple: "x86_64-unknown-linux-gnu", isOptimized: false)

    func testDefaultIsAllClauses() {
        XCTAssertEqual(Configuration().platformConditionalRetention, .allClauses)
        XCTAssertEqual(Configuration().resolvedPlatformConditionalRetention, .allClauses)
    }

    func testDisableFlagIsAnAliasOfOffThatOverridesTheSetting() {
        for retention in PlatformConditionalRetention.allCases {
            let configuration = Configuration()
            configuration.platformConditionalRetention = retention
            XCTAssertEqual(configuration.resolvedPlatformConditionalRetention, retention)

            configuration.disablePlatformConditionalRetention = true
            XCTAssertEqual(configuration.resolvedPlatformConditionalRetention, .off)
        }
    }

    func testAvailabilityPlatformsOfTriples() {
        XCTAssertEqual(macOS.availabilityPlatforms, ["macOS", "OSX"])
        XCTAssertEqual(iOSSimulator.availabilityPlatforms, ["iOS"])
        XCTAssertEqual(iOS.availabilityPlatforms, ["iOS"])
        XCTAssertEqual(catalyst.availabilityPlatforms, ["iOS", "macCatalyst"])
        XCTAssertEqual(IndexVariant(triple: "arm64-apple-xros2.0-simulator", isOptimized: false).availabilityPlatforms, ["visionOS"])
        XCTAssertNil(linux.availabilityPlatforms)
        XCTAssertNil(IndexVariant(triple: "arm64-apple-ios18.0-driverkit", isOptimized: false).availabilityPlatforms)
    }

    func testUnavailableDeclarationIsCoveredByABuildForItsPlatformAndOneWhereItIsAvailable() {
        XCTAssertTrue(IndexVariant.cover(unavailablePlatforms: ["iOS"], in: [macOS, iOSSimulator]))
        XCTAssertTrue(IndexVariant.cover(unavailablePlatforms: ["macOS"], in: [macOS, iOSSimulator]))
        XCTAssertTrue(IndexVariant.cover(unavailablePlatforms: ["OSX"], in: [macOS, iOS]))
        XCTAssertTrue(IndexVariant.cover(unavailablePlatforms: ["iOS", "watchOS"], in: [macOS, iOS]))
    }

    /// A single build never covers a declaration: `auto` then retains exactly what `all-clauses` retains.
    func testASingleBuildNeverCovers() {
        for variant in [macOS, iOSSimulator, iOS, catalyst, watchOS, linux] {
            for platform in ["macOS", "OSX", "iOS", "macCatalyst", "tvOS", "watchOS", "visionOS"] {
                XCTAssertFalse(IndexVariant.cover(unavailablePlatforms: [platform], in: [variant]), "\(variant) \(platform)")
            }
        }
        XCTAssertFalse(IndexVariant.cover(unavailablePlatforms: ["iOS"], in: []))
    }

    func testIsNotCoveredWithoutABuildForBothSides() {
        // Debug and release builds of one platform.
        XCTAssertFalse(IndexVariant.cover(unavailablePlatforms: ["macOS"], in: [macOS, macOSRelease]))
        XCTAssertFalse(IndexVariant.cover(unavailablePlatforms: ["iOS"], in: [macOS, macOSRelease]))
        // No build for the unavailable platform.
        XCTAssertFalse(IndexVariant.cover(unavailablePlatforms: ["watchOS"], in: [macOS, iOSSimulator]))
        // Mac Catalyst inherits the unavailability on iOS.
        XCTAssertFalse(IndexVariant.cover(unavailablePlatforms: ["iOS"], in: [iOSSimulator, catalyst]))
        // A build whose platform is not known with certainty.
        XCTAssertFalse(IndexVariant.cover(unavailablePlatforms: ["macOS"], in: [macOS, iOS, linux]))
        XCTAssertFalse(IndexVariant.cover(unavailablePlatforms: [], in: [macOS, iOS]))
    }

    /// Monday's iOS unit of another target, left in a shared store, predates the iOS-only use added on Tuesday of a
    /// declaration unavailable on macOS: with the macOS unit of Tuesday's build alone, the declaration is not covered.
    func testUnitOlderThanTheFile_doesNotCoverAnUnavailableDeclaration() throws {
        let configuration = Configuration()
        configuration.variants = .auto
        let logger = Logger(quiet: true, verbose: false, colorMode: .never)
        let graph = SourceGraph(configuration: configuration, logger: logger)
        let file = SourceFile(path: FilePath("/App/Shared.swift"), modules: ["App_iOS", "App_macOS"], variants: [macOS, iOS], currentVariants: [macOS])
        let declaration = Declaration(name: "haptics()", kind: .functionFree, usrs: ["s:3App7hapticsyyF"], location: Location(file: file, line: 1, column: 1))
        declaration.attributes = [DeclarationAttribute(name: "available", arguments: "macOS, unavailable")]
        graph.add(declaration)

        try PlatformConditionalRetainer(graph: graph, configuration: configuration, swiftVersion: SwiftVersion(shell: ShellImpl(logger: logger))).mutate()

        XCTAssertTrue(graph.isRetained(declaration))
    }

    func testDescribesOptimizedBuilds() {
        XCTAssertEqual(macOS.description, "arm64-apple-macosx15.0")
        XCTAssertEqual(macOSRelease.description, "arm64-apple-macosx15.0 (optimized)")
        XCTAssertEqual([macOSRelease, iOSSimulator, macOS].sorted(), [iOSSimulator, macOS, macOSRelease])
    }
}
