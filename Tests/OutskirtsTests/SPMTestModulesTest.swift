import Foundation
@testable import ProjectDrivers
import XCTest

final class SPMTestModulesTest: XCTestCase {
    func testTestModules_includeTheTestDiscoveryAndEntryPointModulesGeneratedOnLinux() throws {
        let description = try decode(#"""
        {"name": "My-Package", "targets": [
            {"name": "App", "type": "executable", "path": "Sources/App"},
            {"name": "App-Tests", "c99name": "App_Tests", "type": "test", "path": "Tests/AppTests"}
        ]}
        """#)

        XCTAssertEqual(
            SPMProjectDriver.testModules(of: description),
            ["App_Tests", "App_Tests_test_runner", "My_PackagePackageDiscoveredTests", "My_PackagePackageTests"]
        )
    }

    func testPackageWithoutTestTargets_hasNoTestModules() throws {
        let description = try decode(#"""
        {"name": "Package", "targets": [{"name": "App", "type": "executable", "path": "Sources/App"}]}
        """#)

        XCTAssertEqual(SPMProjectDriver.testModules(of: description), [])
    }

    private func decode(_ json: String) throws -> PackageDescription {
        try JSONDecoder().decode(PackageDescription.self, from: Data(json.utf8))
    }
}
