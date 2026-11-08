import Configuration
import Foundation
@testable import Indexer
@testable import ProjectDrivers
import Shared
import SystemPackage
@testable import TestShared
import XCTest

final class GenericProjectDriverPlanTest: FixtureSourceGraphTestCase {
    /// `enable_unused_system_imports` runs the system module indexer over `IndexPlan.indexStorePaths`, which stayed
    /// empty with a generic project config.
    func testPlanCarriesTheIndexStorePaths() throws {
        let stores = Self.plan.indexStorePaths
        XCTAssertFalse(stores.isEmpty)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("periphery-generic-plan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }

        let json = try JSONSerialization.data(withJSONObject: ["indexstores": stores.map(\.string).sorted()])
        let file = FilePath(directory.appendingPathComponent("config.json").path)
        try json.write(to: file.url)

        let configuration = Configuration()
        configuration.enableUnusedSystemImports = true
        let driver = try GenericProjectDriver(genericProjectConfig: file, configuration: configuration)
        let plan = try driver.plan(logger: Self.logger.contextualized(with: "index"))

        XCTAssertEqual(plan.indexStorePaths, stores)
    }
}
