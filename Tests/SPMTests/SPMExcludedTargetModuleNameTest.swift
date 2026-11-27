import Configuration
import Foundation
import Indexer
@testable import ProjectDrivers
import Shared
import SourceGraph
import SystemPackage
@testable import TestShared
import XCTest

/// `exclude_tests` and `exclude_targets` on a package whose target names are not C identifiers: index units name the
/// module (`My_Lib`), not the target (`My-Lib`).
final class SPMExcludedTargetModuleNameTest: SPMSourceGraphTestCase {
    override static func setUp() {
        super.setUp()
        build(projectPath: SPMHyphenatedProjectPath)
    }

    private func plan(_ configure: (Configuration) -> Void) throws -> IndexPlan {
        let configuration = Configuration()
        configuration.apply(\.$skipBuild, true)
        configure(configuration)
        configuration.buildFilenameMatchers()
        var plan: IndexPlan?
        try SPMHyphenatedProjectPath.chdir {
            plan = try SPMProjectDriver(configuration: configuration, shell: Self.shell, logger: Self.logger).plan(logger: Self.logger.contextualized(with: "index"))
        }
        return try XCTUnwrap(plan)
    }

    private func modules(of plan: IndexPlan) -> Set<String> {
        Set(plan.sourceFiles.keys.flatMap(\.modules))
    }

    func testWithoutExclusion_collectsBothModules() throws {
        let plan = try plan { _ in }

        XCTAssertEqual(modules(of: plan), ["My_Lib", "My_LibTests"])
    }

    func testExcludeTests_leavesOutTheHyphenatedTestTarget() throws {
        let plan = try plan { $0.apply(\.$excludeTests, true) }

        XCTAssertEqual(modules(of: plan), ["My_Lib"])
        XCTAssertEqual(Set(plan.expectedSourceFiles.keys), ["My-Lib"])
    }

    func testExcludeTargets_acceptsTheTargetName() throws {
        let plan = try plan { $0.apply(\.$excludeTargets, ["My-Lib"]) }

        XCTAssertEqual(modules(of: plan), ["My_LibTests"])
        XCTAssertEqual(Set(plan.expectedSourceFiles.keys), ["My-LibTests"])
    }

    func testExcludeTargets_acceptsTheModuleName() throws {
        let plan = try plan { $0.apply(\.$excludeTargets, ["My_LibTests"]) }

        XCTAssertEqual(modules(of: plan), ["My_Lib"])
        XCTAssertEqual(Set(plan.expectedSourceFiles.keys), ["My-Lib"])
    }

    func testTestTargetSources_areMarkedAsTestFiles() throws {
        let plan = try plan { _ in }
        let testFiles = plan.sourceFiles.keys.filter(\.isTestFile)

        XCTAssertEqual(Set(testFiles.map(\.path)), [SPMHyphenatedProjectPath.appending("Tests/My-LibTests/GreeterTests.swift")])
        XCTAssertEqual(Set(testFiles.flatMap(\.modules)), ["My_LibTests"])
    }

    func testUnmatchedExcludedTargets_namesOnlyTheUnknownNames() {
        let targets = ["My-Lib", "My_Lib", "My-LibTests", "My_LibTests"]

        XCTAssertEqual(unmatchedExcludedTargets(["My-Lib", "My_LibTests", "MyLib"], targets: targets), ["MyLib"])
    }
}
