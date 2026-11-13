import Configuration
import Foundation
import Indexer
import IndexStore
@testable import PeripheryKit
import ProjectDrivers
import Shared
import SourceGraph
import SystemPackage
@testable import TestShared
import XCTest

/// `strict_index_coverage` on the index store of a package built with its tests, and on a copy without the test target.
final class SPMStrictIndexCoverageTest: SPMSourceGraphTestCase {
    private var temporaryDirectory: URL?

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try FileManager.default.removeItem(at: temporaryDirectory)
        }
        try super.tearDownWithError()
    }

    private func strictConfiguration() -> Configuration {
        let configuration = Configuration()
        configuration.apply(\.$strictIndexCoverage, true)
        return configuration
    }

    private func resultKeys() -> [String] {
        Self.results.map { "\($0.declaration.usrs.sorted()) \($0.annotation)" }.sorted()
    }

    /// A copy of the store without the units of the module; the records are shared through a symbolic link.
    private func store(_ store: FilePath, withoutModule module: String) throws -> FilePath {
        let directory = try makeTemporaryDirectory("outskirts-coverage")
        temporaryDirectory = directory
        let copy = FilePath(directory.path).appending("store")
        let fileManager = FileManager.default
        try fileManager.createDirectory(atPath: copy.appending("v5/units").string, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(atPath: copy.appending("v5/records").string, withDestinationPath: store.appending("v5/records").string)

        let indexStore = try IndexStore(path: store.string)
        var removed = 0
        for name in indexStore.unitNames {
            guard try UnitReader(indexStore: indexStore, unitName: name).moduleName != module else {
                removed += 1
                continue
            }

            try fileManager.copyItem(atPath: store.appending("v5/units/\(name)").string, toPath: copy.appending("v5/units/\(name)").string)
        }
        XCTAssertGreaterThan(removed, 0, "no unit of module \(module) in \(store)")

        return copy
    }

    private func pipeline(_ configuration: Configuration) throws -> IndexPipeline {
        var plan: IndexPlan?
        try SPMProjectPath.chdir {
            plan = try SPMProjectDriver(configuration: configuration, shell: Self.shell, logger: Self.logger).plan(logger: Self.logger.contextualized(with: "index"))
        }

        return try IndexPipeline(
            plan: XCTUnwrap(plan),
            graph: SourceGraphMutex(graph: SourceGraph(configuration: configuration, logger: Self.logger)),
            logger: Self.logger.contextualized(with: "index"),
            configuration: configuration,
            swiftVersion: Self.swiftVersion
        )
    }

    func testCompleteIndex_passesWithTheResultsOfAScanWithoutTheOption() {
        Self.build(projectPath: SPMProjectPath)
        Self.index(configuration: Configuration())
        let expected = resultKeys()

        let configuration = strictConfiguration()
        Self.build(projectPath: SPMProjectPath, configuration: configuration)
        Self.index(configuration: configuration)

        XCTAssertFalse(expected.isEmpty)
        XCTAssertEqual(resultKeys(), expected)
    }

    func testIndexWithoutTheTestTarget_failsNamingItAndItsPlatform() throws {
        Self.build(projectPath: SPMProjectPath)
        let partial = try store(XCTUnwrap(Self.plan.indexStorePaths.first), withoutModule: "Tests")

        let configuration = strictConfiguration()
        configuration.apply(\.$skipBuild, true)
        configuration.apply(\.$indexStorePath, [partial])

        XCTAssertThrowsError(try pipeline(configuration).perform()) { error in
            guard case let PeripheryError.incompleteIndexCoverage(message) = error else {
                return XCTFail("unexpected error \(error)")
            }

            XCTAssertTrue(message.contains("no index data for target(s) 'Tests' on \(IndexPlatform.host)"), message)
            XCTAssertFalse(message.contains("SPMProjectKit"), message)
        }

        configuration.apply(\.$excludeTargets, ["Tests"])
        XCTAssertNoThrow(try pipeline(configuration).perform())

        configuration.apply(\.$excludeTargets, [])
        configuration.apply(\.$strictIndexCoverage, false)
        XCTAssertNoThrow(try pipeline(configuration).perform())
    }
}
