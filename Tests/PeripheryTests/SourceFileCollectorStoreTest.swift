import Configuration
import Foundation
@testable import Indexer
import Shared
import SourceGraph
import SystemPackage
@testable import TestShared
import XCTest

/// `SourceFileCollector` over the index store of the fixtures package.
final class SourceFileCollectorStoreTest: FixtureSourceGraphTestCase {
    private func collect(
        excludeTargets: [String] = [],
        excludedTestTargets: Set<String> = [],
        indexExclude: [String] = []
    ) throws -> (sourceFiles: [SourceFile: [IndexUnit]], indexExcludedFiles: Set<FilePath>, unreadableUnits: [String]) {
        let configuration = Configuration()
        configuration.apply(\.$excludeTargets, excludeTargets)
        configuration.apply(\.$indexExclude, indexExclude)
        configuration.buildFilenameMatchers()
        return try SourceFileCollector(
            indexStorePaths: Self.plan.indexStorePaths,
            excludedTestTargets: excludedTestTargets,
            logger: Self.logger.contextualized(with: "test"),
            configuration: configuration
        ).collectWithIndexExcludedFiles()
    }

    private func files(ofModule module: String, in sourceFiles: [SourceFile: [IndexUnit]]) -> Set<FilePath> {
        Set(sourceFiles.keys.filter { $0.modules.contains(module) }.map(\.path))
    }

    func testCollectsEveryModuleWithoutExclusions() throws {
        let collected = try collect()

        XCTAssertFalse(files(ofModule: "UnusedImportFixtureA", in: collected.sourceFiles).isEmpty)
        XCTAssertFalse(files(ofModule: "UnusedImportFixtureB", in: collected.sourceFiles).isEmpty)
        XCTAssertEqual(collected.indexExcludedFiles, [])
        XCTAssertEqual(collected.unreadableUnits, [])
    }

    func testExcludedTargetsAndExcludedTestTargetsAreDropped() throws {
        let all = try collect().sourceFiles
        let collected = try collect(excludeTargets: ["UnusedImportFixtureA"], excludedTestTargets: ["UnusedImportFixtureB"])

        XCTAssertEqual(files(ofModule: "UnusedImportFixtureA", in: collected.sourceFiles), [])
        XCTAssertEqual(files(ofModule: "UnusedImportFixtureB", in: collected.sourceFiles), [])
        XCTAssertEqual(files(ofModule: "UnusedImportFixtureC", in: collected.sourceFiles), files(ofModule: "UnusedImportFixtureC", in: all))
        XCTAssertEqual(collected.indexExcludedFiles, [], "excluded targets are not index-excluded files")
    }

    func testIndexExcludedFilesAreSeparatedFromTheSourceFiles() throws {
        let all = try collect().sourceFiles
        let excluded = files(ofModule: "UnusedImportFixtureA", in: all)
        XCTAssertFalse(excluded.isEmpty)

        let collected = try collect(indexExclude: excluded.map(\.string))

        XCTAssertEqual(collected.indexExcludedFiles, excluded)
        XCTAssertTrue(Set(collected.sourceFiles.keys.map(\.path)).isDisjoint(with: excluded))
        XCTAssertEqual(collected.sourceFiles.count, all.count - excluded.count)
    }
}
