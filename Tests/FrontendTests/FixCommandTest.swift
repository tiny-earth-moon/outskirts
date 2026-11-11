import Configuration
@testable import Frontend
import Shared
import SystemPackage
import XCTest

final class FixCommandTest: XCTestCase {
    func testOptionsThatWriteOtherFilesAreRefused() {
        for arguments in [["--write-results", "r.txt"], ["--write-baseline", "b.json"], ["--baseline", "b.json", "--prune-baseline"], ["--setup"]] {
            XCTAssertThrowsError(try FixCommand.parse(arguments), "\(arguments)")
        }
    }

    func testScanOptionsAndFixFlagsParse() throws {
        let command = try FixCommand.parse(["--apply", "--include", "a/**", "--include", "b/**", "--allow-dirty", "--allow-partial-scan", "--allow-runtime-keys", "--exclude-tests"])

        XCTAssertTrue(command.fixOptions.apply)
        XCTAssertEqual(command.fixOptions.includes, ["a/**", "b/**"])
        XCTAssertTrue(command.fixOptions.allowDirty && command.fixOptions.allowPartialScan && command.fixOptions.allowRuntimeKeys)
        XCTAssertEqual(command.scan.buildOptions.excludeTests, true)
    }

    func testDefaultSwiftPackageScanIsComplete() {
        XCTAssertNil(FixCommand.PartialScan(of: .spm, configuration: Configuration()))
    }

    func testOptionsThatLeaveCodeOutAreAPartialScan() {
        let indexExclude = Configuration()
        indexExclude.indexExclude = indexExclude.$indexExclude.defaultValue + ["Sources/Generated/**"]
        let excludeTests = Configuration()
        excludeTests.excludeTests = true
        let excludeTargets = Configuration()
        excludeTargets.excludeTargets = ["Other"]

        XCTAssertEqual(FixCommand.PartialScan(of: .spm, configuration: indexExclude), .narrowing("index_exclude"))
        XCTAssertEqual(FixCommand.PartialScan(of: .spm, configuration: excludeTests), .narrowing("exclude_tests"))
        XCTAssertEqual(FixCommand.PartialScan(of: .spm, configuration: excludeTargets), .narrowing("exclude_targets"))
        XCTAssertEqual(FixCommand.PartialScan(of: .xcode(projectPath: "App.xcodeproj"), configuration: Configuration()), .xcodeProject)
    }

    func testPartialScanRefusalIsAUsageErrorUnlessAllowed() throws {
        let configuration = Configuration()
        configuration.excludeTests = true

        XCTAssertThrowsError(try FixCommand.validateScope(of: configuration, projectKind: .spm, allowPartialScan: false)) { error in
            XCTAssertTrue("\(error)".contains("Remove 'exclude_tests'. Pass '--allow-partial-scan' to accept this."), "\(error)")
        }
        XCTAssertNoThrow(try FixCommand.validateScope(of: configuration, projectKind: .spm, allowPartialScan: true))
    }

    func testDisabledAnalysisIsRefusedEvenWithAllowPartialScan() {
        let configuration = Configuration()
        configuration.disableUnusedLocalizedStringAnalysis = true

        XCTAssertThrowsError(try FixCommand.validateScope(of: configuration, projectKind: .spm, allowPartialScan: true))
    }

    func testRuntimeKeysAreNotRefusedWithoutCallSites() {
        XCTAssertNil(FixCommand.runtimeKeysRefusal([], configuration: Configuration()))
    }
}
