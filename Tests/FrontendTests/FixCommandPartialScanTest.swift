import Configuration
@testable import Frontend
import Shared
import XCTest

/// The scans after which `fix --rule unused` is refused without `--allow-partial-scan`.
final class FixCommandPartialScanTest: XCTestCase {
    func testAnXcodeProjectIsRefusedAsOnlyTheListedSchemesInDebugAreBuilt() throws {
        let refusal = try XCTUnwrap(FixCommand.partialScanRefusal(of: .xcode(projectPath: "App.xcodeproj"), configuration: Configuration()))

        XCTAssertTrue(refusal.contains("an Xcode project is only built for the listed schemes in the Debug configuration"), refusal)
        XCTAssertTrue(refusal.contains("EXCLUDED_SOURCE_FILE_NAMES"), refusal)
        XCTAssertTrue(refusal.contains("'--allow-partial-scan'"), refusal)
    }

    func testAPackageIsOnlyRefusedWhenAnOptionLeavesCodeOutOfTheScan() {
        XCTAssertNil(FixCommand.partialScanRefusal(of: .spm, configuration: Configuration()))

        let configuration = Configuration()
        configuration.excludeTests = true
        XCTAssertEqual(
            FixCommand.partialScanRefusal(of: .spm, configuration: configuration)?.contains("but 'exclude_tests' leaves code out of the scan"),
            true
        )
    }
}
