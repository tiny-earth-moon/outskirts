import Configuration
@testable import PeripheryKit
@testable import TestShared
import XCTest

final class SPMProjectBuildPluginTest: SPMSourceGraphTestCase {
    private static let configuration: Configuration = {
        let configuration = Configuration()
        configuration.buildFilenameMatchers()
        return configuration
    }()

    override static func setUp() {
        super.setUp()

        build(projectPath: SPMProjectBuildPluginPath, configuration: configuration)
        index(configuration: configuration)
    }

    func testDeclarationUsedOnlyByPluginGeneratedCode_isReferenced() {
        assertReferenced(.functionFree("usedOnlyByGeneratedCode()"))
        assertNotReferenced(.functionFree("unusedInProject()"))
    }

    func testPluginGeneratedCode_isIndexedButNotReported() throws {
        XCTAssertTrue(Self.results.contains(where: isGenerated), "the generated code is indexed")

        let reported = try OutputDeclarationFilter(configuration: Self.configuration, logger: Self.logger).filter(Self.results, with: nil)

        XCTAssertFalse(reported.contains(where: isGenerated))
        XCTAssertTrue(reported.contains { $0.declaration.name == "unusedInProject()" })
    }

    // MARK: - Private

    private func isGenerated(_ result: ScanResult) -> Bool {
        result.declaration.location.file.path.lastComponent?.string == "GeneratedCalls.swift"
    }
}
