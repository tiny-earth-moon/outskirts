import Configuration
import Foundation
@testable import Indexer
import Logger
import Shared
import SourceGraph
import SystemPackage
import XCTest

/// `strict_index_coverage` judges each target per platform, from the module and triple of the units of its files.
final class IndexCoverageStrictTest: XCTestCase {
    private typealias Unit = IndexCoverage.IndexedUnit

    private let shared = FilePath("/app/Shared/Model.swift")
    private let iOSOnly = FilePath("/app/iOS/Scene.swift")
    private let macOSOnly = FilePath("/app/macOS/Window.swift")
    private let test = FilePath("/app/Tests/ModelTests.swift")

    private let iOSTargets: [String: Set<FilePath>] = [
        "App (iOS)": ["/app/Shared/Model.swift", "/app/iOS/Scene.swift"],
        "App (macOS)": ["/app/Shared/Model.swift", "/app/macOS/Window.swift"],
    ]

    private func unit(_ module: String, _ triple: String) -> Unit {
        Unit(module: module, platform: IndexPlatform(triple: triple))
    }

    private var twoPlatformTargets: [String: CoverageTarget] {
        [
            "App (iOS)": CoverageTarget(moduleName: "App", platforms: [.iOS]),
            "App (macOS)": CoverageTarget(moduleName: "App", platforms: [.macOS]),
            "AppTests": CoverageTarget(moduleName: "AppTests", platforms: [.iOS]),
        ]
    }

    func testPlatformsAreReadFromTriplesAndSDKs() {
        XCTAssertEqual(IndexPlatform(triple: "arm64-apple-ios17.0-simulator"), .iOS)
        XCTAssertEqual(IndexPlatform(triple: "arm64-apple-ios17.0"), .iOS)
        XCTAssertEqual(IndexPlatform(triple: "arm64-apple-ios17.0-macabi"), .macCatalyst)
        XCTAssertEqual(IndexPlatform(triple: "x86_64-apple-macosx14.0"), .macOS)
        XCTAssertEqual(IndexPlatform(triple: "arm64-apple-xros2.0-simulator"), .visionOS)
        XCTAssertEqual(IndexPlatform(triple: "x86_64-unknown-linux-gnu"), .linux)
        XCTAssertNil(IndexPlatform(triple: "wasm32"))
        XCTAssertEqual(IndexPlatform(sdk: "iphonesimulator"), .iOS)
        XCTAssertEqual(IndexPlatform(sdk: "macosx"), .macOS)
        XCTAssertEqual(IndexPlatform(sdk: "watchsimulator"), .watchOS)
        XCTAssertNil(IndexPlatform(sdk: "auto"))
    }

    /// Files shared by an iOS and a macOS target are indexed by the iOS build alone: the macOS target is still missing.
    func testIndexOfOnePlatform_reportsTheTargetOfTheOtherPlatform() {
        let units: [FilePath: Set<Unit>] = [
            shared: [unit("App", "arm64-apple-ios17.0-simulator")],
            iOSOnly: [unit("App", "arm64-apple-ios17.0-simulator")],
        ]

        let shortfalls = IndexCoverage.shortfalls(expected: iOSTargets, units: units, targets: twoPlatformTargets)

        XCTAssertEqual(shortfalls, [.target("App (macOS)", platforms: [.macOS])])
    }

    func testMultiplatformTargetBuiltForOnePlatform_reportsTheMissingPlatform() {
        let expected: [String: Set<FilePath>] = ["Kit": [shared]]
        let targets = ["Kit": CoverageTarget(moduleName: "Kit", platforms: [.iOS, .macOS, .visionOS])]
        let units: [FilePath: Set<Unit>] = [shared: [unit("Kit", "arm64-apple-ios17.0"), unit("Kit", "arm64-apple-ios17.0-macabi")]]

        XCTAssertEqual(
            IndexCoverage.shortfalls(expected: expected, units: units, targets: targets),
            [.target("Kit", platforms: [.macOS, .visionOS])]
        )
    }

    func testIndexWithoutTestTargets_reportsThem() {
        var expected = iOSTargets
        expected["AppTests"] = [test]
        let units: [FilePath: Set<Unit>] = [
            shared: [unit("App", "arm64-apple-ios17.0"), unit("App", "arm64-apple-macosx14.0")],
            iOSOnly: [unit("App", "arm64-apple-ios17.0")],
            macOSOnly: [unit("App", "arm64-apple-macosx14.0")],
        ]

        XCTAssertEqual(
            IndexCoverage.shortfalls(expected: expected, units: units, targets: twoPlatformTargets),
            [.target("AppTests", platforms: [.iOS])]
        )
    }

    func testCompleteIndex_hasNoShortfall() {
        var expected = iOSTargets
        expected["AppTests"] = [test]
        let units: [FilePath: Set<Unit>] = [
            shared: [unit("App", "arm64-apple-ios17.0"), unit("App", "arm64-apple-macosx14.0")],
            iOSOnly: [unit("App", "arm64-apple-ios17.0")],
            macOSOnly: [unit("App", "arm64-apple-macosx14.0")],
            test: [unit("AppTests", "arm64-apple-ios17.0")],
        ]

        XCTAssertEqual(IndexCoverage.shortfalls(expected: expected, units: units, targets: twoPlatformTargets), [])
    }

    /// A file of a target that only another target of the same platform compiled has no index data of its own.
    func testFileIndexedOnlyForAnotherModule_isReportedForItsTarget() {
        let widgetFile = FilePath("/app/Widget/Widget.swift")
        let expected: [String: Set<FilePath>] = ["App": [shared], "Widget": [shared, widgetFile]]
        let targets = [
            "App": CoverageTarget(moduleName: "App", platforms: [.iOS]),
            "Widget": CoverageTarget(moduleName: "Widget", platforms: [.iOS]),
        ]
        let units: [FilePath: Set<Unit>] = [shared: [unit("App", "arm64-apple-ios17.0")], widgetFile: [unit("Widget", "arm64-apple-ios17.0")]]

        XCTAssertEqual(IndexCoverage.shortfalls(expected: expected, units: units, targets: targets), [.files("Widget", [shared])])
    }

    /// A module name that no unit has is likely read wrongly from the project: units of any module then cover it.
    func testModuleNameAbsentFromTheIndex_fallsBackToAnyModule() {
        let expected: [String: Set<FilePath>] = ["App": [shared]]
        let targets = ["App": CoverageTarget(moduleName: "NotTheModule", platforms: [.iOS])]
        let units: [FilePath: Set<Unit>] = [shared: [unit("App", "arm64-apple-ios17.0")]]

        XCTAssertEqual(IndexCoverage.shortfalls(expected: expected, units: units, targets: targets), [])
    }

    func testTargetWithUnknownPlatformsAndNoUnit_isReported() {
        let expected: [String: Set<FilePath>] = ["App": [shared], "Tool": [macOSOnly]]
        let units: [FilePath: Set<Unit>] = [shared: [unit("App", "arm64-apple-macosx14.0")]]

        XCTAssertEqual(IndexCoverage.shortfalls(expected: expected, units: units, targets: [:]), [.target("Tool", platforms: [])])
    }

    func testMessage_namesTargetsPlatformsAndFiles() {
        let message = IndexCoverage.incompleteCoverageMessage(
            [.target("App (macOS)", platforms: [.macOS]), .target("Tool", platforms: []), .files("Widget", [shared, iOSOnly, macOSOnly, test])],
            storeList: "/dd/Index.noindex/DataStore",
            relativeTo: "/app"
        )

        XCTAssertTrue(message.contains("no index data for target(s) 'App (macOS)' on macOS, 'Tool';"), message)
        XCTAssertTrue(message.contains("4 source file(s) of 'Widget' (Shared/Model.swift, iOS/Scene.swift, macOS/Window.swift and 1 more)"), message)
        XCTAssertTrue(message.contains("(index store: /dd/Index.noindex/DataStore)"), message)
        XCTAssertTrue(message.hasSuffix("Failing as '--strict-index-coverage' is set."), message)
    }

    func testVerify_throwsATypedErrorOnlyWithTheOption() throws {
        let plan = IndexPlan(
            sourceFiles: [SourceFile(path: shared, modules: ["App"]): []],
            expectedSourceFiles: ["App": [shared], "AppTests": [test]],
            coverageTargets: ["AppTests": CoverageTarget(moduleName: "AppTests", platforms: [.iOS])],
            indexStorePaths: ["/dd/store"]
        )
        let logger = Logger(quiet: true, verbose: false, colorMode: .never).contextualized(with: "test")
        let configuration = Configuration()

        XCTAssertEqual(try IndexCoverage(plan: plan, logger: logger, configuration: configuration).verify(), [])

        configuration.apply(\.$strictIndexCoverage, true)
        XCTAssertThrowsError(try IndexCoverage(plan: plan, logger: logger, configuration: configuration).verify()) { error in
            guard case let PeripheryError.incompleteIndexCoverage(message) = error else {
                return XCTFail("unexpected error \(error)")
            }

            XCTAssertTrue(message.contains("'AppTests' on iOS"), message)
        }
    }
}
