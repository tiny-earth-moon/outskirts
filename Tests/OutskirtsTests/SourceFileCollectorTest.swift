import Configuration
import Foundation
@testable import Indexer
import Logger
import Shared
import SystemPackage
import TestShared
import XCTest

final class SourceFileCollectorTest: XCTestCase {
    private struct Unit: Equatable {
        let name: String
        let module: String
        let date: Date?
        var platform: IndexPlatform?
    }

    private let edited = Date(timeIntervalSince1970: 1000)

    private func current(_ units: [Unit], sourceModificationDate: Date?) -> [String] {
        SourceFileCollector.currentUnits(
            units,
            sourceModificationDate: sourceModificationDate,
            module: \.module,
            platform: \.platform,
            modificationDate: \.date
        ).map(\.name)
    }

    /// A renamed package (or a restored CI cache) leaves the previous build's units next to the new ones.
    func testUnitOlderThanSource_isDroppedWhenItsModuleHasACurrentUnit() {
        let units = [
            Unit(name: "stale", module: "Frontend", date: edited.addingTimeInterval(-60), platform: .macOS),
            Unit(name: "fresh", module: "Frontend", date: edited.addingTimeInterval(60), platform: .macOS),
        ]

        XCTAssertEqual(current(units, sourceModificationDate: edited), ["fresh"])
    }

    /// Two stores of a module, one per platform: rebuilding one platform says nothing of the other one.
    func testUnitOlderThanSource_isKeptWhenOnlyAnotherPlatformHasACurrentUnit() {
        let units = [
            Unit(name: "ios", module: "Kit", date: edited.addingTimeInterval(-60), platform: .iOS),
            Unit(name: "macos", module: "Kit", date: edited.addingTimeInterval(60), platform: .macOS),
            Unit(name: "unknown", module: "Kit", date: edited.addingTimeInterval(-60)),
        ]

        XCTAssertEqual(current(units, sourceModificationDate: edited), ["ios", "macos", "unknown"])
    }

    func testUnitOfUnknownPlatform_isDroppedWhenAnotherUnitOfUnknownPlatformIsCurrent() {
        let units = [
            Unit(name: "stale", module: "Kit", date: edited.addingTimeInterval(-60)),
            Unit(name: "fresh", module: "Kit", date: edited.addingTimeInterval(60)),
            Unit(name: "ios", module: "Kit", date: edited.addingTimeInterval(-60), platform: .iOS),
        ]

        XCTAssertEqual(current(units, sourceModificationDate: edited), ["fresh", "ios"])
    }

    func testUnitsOfSeveralProducts_areAllKeptWhenCurrent() {
        let units = [
            Unit(name: "outskirts", module: "Frontend", date: edited.addingTimeInterval(10)),
            Unit(name: "periphery", module: "Frontend", date: edited.addingTimeInterval(20)),
            Unit(name: "testable", module: "Frontend", date: edited),
        ]

        XCTAssertEqual(current(units, sourceModificationDate: edited), ["outskirts", "periphery", "testable"])
    }

    func testOnlyUnitsOlderThanSource_areKept() {
        let units = [
            Unit(name: "a", module: "Frontend", date: edited.addingTimeInterval(-60)),
            Unit(name: "b", module: "Frontend", date: edited.addingTimeInterval(-30)),
        ]

        XCTAssertEqual(current(units, sourceModificationDate: edited), ["a", "b"])
    }

    func testOutdatedUnitOfAnotherModule_isKept() {
        let units = [
            Unit(name: "lib", module: "Lib", date: edited.addingTimeInterval(60)),
            Unit(name: "app", module: "App", date: edited.addingTimeInterval(-60)),
        ]

        XCTAssertEqual(current(units, sourceModificationDate: edited), ["lib", "app"])
    }

    func testUnknownDates_keepAllUnits() {
        let units = [
            Unit(name: "undated", module: "Frontend", date: nil),
            Unit(name: "fresh", module: "Frontend", date: edited.addingTimeInterval(60)),
            Unit(name: "stale", module: "Frontend", date: edited.addingTimeInterval(-60)),
        ]

        XCTAssertEqual(current(units, sourceModificationDate: edited), ["undated", "fresh"])
        XCTAssertEqual(current(units, sourceModificationDate: nil), ["undated", "fresh", "stale"])
    }

    private func outdated(_ units: [Unit], sourceModificationDate: Date?) -> [String] {
        let kept = SourceFileCollector.currentUnits(
            units,
            sourceModificationDate: sourceModificationDate,
            module: \.module,
            platform: \.platform,
            modificationDate: \.date
        )

        return SourceFileCollector.outdatedUnits(
            kept,
            sourceModificationDate: sourceModificationDate,
            modificationDate: \.date
        ).map(\.name)
    }

    /// Edited after the last build, scanned with `--skip-build`: the only units of the file describe an older version.
    func testSourceNewerThanItsOnlyUnits_isOutdated() {
        let units = [
            Unit(name: "macos", module: "Kit", date: edited.addingTimeInterval(-60)),
            Unit(name: "ios", module: "Kit", date: edited.addingTimeInterval(-30)),
        ]

        XCTAssertEqual(outdated(units, sourceModificationDate: edited), ["macos", "ios"])
    }

    func testUnitsWrittenAfterTheSource_areNotOutdated() {
        let units = [
            Unit(name: "macos", module: "Kit", date: edited.addingTimeInterval(60)),
            Unit(name: "ios", module: "Kit", date: edited),
        ]

        XCTAssertEqual(outdated(units, sourceModificationDate: edited), [])
    }

    /// The stale unit is dropped in favour of the fresh one, so the results are correct and need no warning.
    func testStaleUnitBesideAFreshUnitOfItsModuleAndPlatform_isNotOutdated() {
        let units = [
            Unit(name: "previous", module: "Kit", date: edited.addingTimeInterval(-60), platform: .iOS),
            Unit(name: "rebuilt", module: "Kit", date: edited.addingTimeInterval(60), platform: .iOS),
        ]

        XCTAssertEqual(outdated(units, sourceModificationDate: edited), [])
    }

    /// Edited, then only macOS rebuilt: the iOS unit is the only index data of the iOS build, and is outdated.
    func testStaleUnitBesideAFreshUnitOfAnotherPlatform_isOutdated() {
        let units = [
            Unit(name: "ios", module: "Kit", date: edited.addingTimeInterval(-60), platform: .iOS),
            Unit(name: "macos", module: "Kit", date: edited.addingTimeInterval(60), platform: .macOS),
        ]

        XCTAssertEqual(outdated(units, sourceModificationDate: edited), ["ios"])
    }

    func testUnknownDates_areNotOutdated() {
        let units = [
            Unit(name: "undated", module: "Kit", date: nil),
            Unit(name: "stale", module: "Kit", date: edited.addingTimeInterval(-60)),
        ]

        XCTAssertEqual(outdated(units, sourceModificationDate: edited), ["stale"])
        XCTAssertEqual(outdated(units, sourceModificationDate: nil), [])
        XCTAssertEqual(outdated([units[0]], sourceModificationDate: edited), [])
    }

    func testOutdatedIndexWarning_isNilWithoutOutdatedFiles() {
        XCTAssertNil(SourceFileCollector.outdatedIndexWarning([:], relativeTo: "/project"))
        XCTAssertNil(SourceFileCollector.outdatedIndexWarning(["/project/.build/out": []], relativeTo: "/project"))
    }

    func testOutdatedIndexWarning_namesTheStoreAndTheFile() {
        let warning = SourceFileCollector.outdatedIndexWarning(
            ["/project/.build-ios/out": ["/project/Sources/Kit/SameName.swift"]],
            relativeTo: "/project"
        )

        XCTAssertEqual(
            warning,
            "1 source file is newer than its index data in .build-ios/out: Sources/Kit/SameName.swift. Results in it may be at the wrong lines or missing: rebuild the project before scanning, or pass '--clean-build' to start from an empty index store."
        )
    }

    func testOutdatedIndexWarning_countsEveryFileAndListsAFewPerStore() {
        let mac: Set<FilePath> = ["/project/Sources/A.swift", "/project/Sources/B.swift"]
        let ios: Set<FilePath> = Set((1 ... 5).map { FilePath("/project/Sources/F\($0).swift") })
        let warning = SourceFileCollector.outdatedIndexWarning(
            ["/project/.build-mac/out": mac, "/elsewhere/DataStore": ios],
            relativeTo: "/project"
        )

        XCTAssertEqual(
            warning,
            "7 source files are newer than their index data: 5 in /elsewhere/DataStore (Sources/F1.swift, Sources/F2.swift, Sources/F3.swift and 2 more), 2 in .build-mac/out (Sources/A.swift, Sources/B.swift). Results in them may be at the wrong lines or missing: rebuild the project before scanning, or pass '--clean-build' to start from an empty index store."
        )
    }

    func testStrictIndex_failsTheScanOnOutdatedFiles() {
        let outdated: [FilePath: Set<FilePath>] = ["/project/.build/out": ["/project/Sources/Beta.swift"]]

        XCTAssertThrowsError(try SourceFileCollector.outdatedIndexWarning(outdated, relativeTo: "/project", strict: true)) { error in
            guard case let .outdatedIndexData(message)? = error as? PeripheryError else {
                return XCTFail("Unexpected error: \(error)")
            }

            XCTAssertTrue(message.hasPrefix("1 source file is newer than its index data in .build/out: Sources/Beta.swift."))
            XCTAssertTrue(message.hasSuffix("Failing as '--strict-index' is set."))
        }
    }

    func testStrictIndex_passesWithAFreshIndex() throws {
        XCTAssertNil(try SourceFileCollector.outdatedIndexWarning([:], relativeTo: "/project", strict: true))
        XCTAssertNil(try SourceFileCollector.outdatedIndexWarning(["/project/.build/out": []], relativeTo: "/project", strict: true))
    }

    func testWithoutStrictIndex_outdatedFilesOnlyWarn() throws {
        let outdated: [FilePath: Set<FilePath>] = ["/project/.build/out": ["/project/Sources/Beta.swift"]]

        XCTAssertEqual(
            try SourceFileCollector.outdatedIndexWarning(outdated, relativeTo: "/project", strict: false),
            SourceFileCollector.outdatedIndexWarning(outdated, relativeTo: "/project")
        )
    }

    // MARK: - Unreadable units

    /// An index store without any unit, as a build that never ran or wrote elsewhere leaves it.
    private func emptyStore() throws -> URL {
        let root = uniqueTemporaryURL("outskirts-index-store")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("v5/units"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("v5/records"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    /// An index store whose only unit has invalid bytes, as left by an interrupted build or a truncated CI cache.
    private func storeWithTruncatedUnit() throws -> FilePath {
        let root = try emptyStore()
        try Data("not a unit".utf8).write(to: root.appendingPathComponent("v5/units/Truncated.swift.o-1ABCDEF"))
        return FilePath(root.path)
    }

    private func collector(store: FilePath, strictIndex: Bool) -> SourceFileCollector {
        let configuration = Configuration()
        configuration.apply(\.$strictIndex, strictIndex)
        return SourceFileCollector(
            indexStorePaths: [store],
            excludedTestTargets: [],
            logger: Logger(quiet: true, verbose: false, colorMode: .never).contextualized(with: "test"),
            configuration: configuration
        )
    }

    func testTruncatedUnit_failsInsteadOfDroppingFile() throws {
        let store = try storeWithTruncatedUnit()

        XCTAssertThrowsError(try collector(store: store, strictIndex: true).collect()) { error in
            guard case let .unreadableIndexUnits(message)? = error as? PeripheryError else {
                return XCTFail("Unexpected error: \(error)")
            }

            XCTAssertTrue(message.contains("1 index store unit cannot be read"), message)
            XCTAssertTrue(message.contains("Truncated.swift.o-1ABCDEF"), message)
            XCTAssertTrue(message.hasSuffix("Failing as '--strict-index' is set."), message)
        }
    }

    /// A generic project config has no expected files, so the coverage check cannot notice an empty store.
    func testEmptyStore_withoutExpectedFiles_throws() throws {
        let store = try FilePath(emptyStore().path)

        XCTAssertThrowsError(try collector(store: store, strictIndex: false).collect()) { error in
            guard case let .emptyIndexStore(stores)? = error as? PeripheryError else {
                return XCTFail("Unexpected error: \(error)")
            }

            XCTAssertEqual(stores, [store.string])
        }
    }

    func testTruncatedUnitWithoutStrictIndex_stillFailsAsNoFileIsLeft() throws {
        let store = try storeWithTruncatedUnit()

        XCTAssertThrowsError(try collector(store: store, strictIndex: false).collect()) { error in
            guard case .emptyIndexStore? = error as? PeripheryError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testUnreadableUnitsWarning_countsEveryUnitAndListsAFewPerStore() {
        let warning = SourceFileCollector.unreadableUnitsWarning(
            ["/project/.build/store": ["A.o-1", "B.o-2", "C.o-3", "D.o-4"], "/elsewhere/DataStore": ["E.o-5"]],
            relativeTo: "/project"
        )

        XCTAssertEqual(
            warning,
            "5 index store units cannot be read: 4 in .build/store (A.o-1, B.o-2, C.o-3 and 1 more), 1 in /elsewhere/DataStore (E.o-5). The source files they describe are left out of the scan, so declarations used only there may be reported as unused: rebuild the project before scanning, or pass '--clean-build' to start from an empty index store."
        )
    }

    func testReadableStore_hasNoUnreadableUnitsWarning() throws {
        XCTAssertNil(try SourceFileCollector.unreadableUnitsWarning([:], relativeTo: "/project", strict: true))
        XCTAssertNil(try SourceFileCollector.unreadableUnitsWarning(["/project/.build/store": []], relativeTo: "/project", strict: true))
    }
}
