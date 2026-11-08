import Configuration
import Fix
@testable import Frontend
import ProjectDrivers
import Shared
import XCTest

/// The scans after which `fix` refuses a rule that needs a scan of all the code, unless `--allow-partial-scan` is given.
final class FixCommandPartialScanTest: XCTestCase {
    func testASingleVariantScanIsRefused() throws {
        let refusal = try XCTUnwrap(FixCommand.partialScanRefusal(for: .redundantPublic, of: .spm, configuration: Configuration()))

        XCTAssertTrue(refusal.hasPrefix("'--rule redundant-public' is only safe once every variant that ships is scanned"), refusal)
        XCTAssertTrue(refusal.contains("Set 'variants' to 'auto' or to a list of variants."), refusal)
    }

    func testAnXcodeProjectIsRefusedAsOnlyTheListedSchemesInDebugAreBuilt() throws {
        let refusal = try XCTUnwrap(FixCommand.partialScanRefusal(for: .redundantPublic, of: .xcode(projectPath: "App.xcodeproj"), configuration: everyVariant()))

        XCTAssertTrue(refusal.contains("an Xcode project is only built for the listed schemes in the Debug configuration"), refusal)
        XCTAssertTrue(refusal.contains("EXCLUDED_SOURCE_FILE_NAMES"), refusal)
        XCTAssertTrue(refusal.hasSuffix("Pass '--allow-partial-scan' to accept this."), refusal)
    }

    func testAPackageIsOnlyRefusedWhenAnOptionLeavesCodeOutOfTheScan() {
        XCTAssertNil(FixCommand.partialScanRefusal(for: .redundantPublic, of: .spm, configuration: everyVariant()))

        let configuration = everyVariant()
        configuration.excludeTests = true
        XCTAssertEqual(
            FixCommand.partialScanRefusal(for: .redundantPublic, of: .spm, configuration: configuration)?.contains("but 'exclude_tests' leaves code out of the scan"),
            true
        )
    }

    func testAScanWhoseVariantsWereNotAllBuiltByThisRunIsRefused() throws {
        XCTAssertNoThrow(try FixCommand.validateVariantCoverage(of: Driver(built: ["arm64-apple-macosx15.0"]), for: .redundantPublic))

        let skipped = Driver(built: ["arm64-apple-macosx15.0"], skipped: ["Skipping the declared platform 'maccatalyst'"])
        XCTAssertThrowsError(try FixCommand.validateVariantCoverage(of: skipped, for: .redundantPublic)) { error in
            XCTAssertTrue("\(error)".contains("some were not built:\nSkipping the declared platform 'maccatalyst'"), "\(error)")
        }

        XCTAssertThrowsError(try FixCommand.validateVariantCoverage(of: Driver(built: []), for: .redundantPublic)) { error in
            XCTAssertTrue("\(error)".contains("this scan did not build its variants"), "\(error)")
        }
    }

    func testTheRulesThatChangeWhatOtherFilesMayDoRequireACompleteScan() {
        XCTAssertEqual(FixRule.allCases.filter(\.requiresCompleteScan), [.redundantPublic, .redundantOpen, .missingFinal])
    }

    // MARK: - Private

    private struct Driver: ProjectDriver {
        let builtVariants: [String]
        let skippedVariants: [String]

        init(built: [String], skipped: [String] = []) {
            builtVariants = built
            skippedVariants = skipped
        }
    }

    private func everyVariant() -> Configuration {
        let configuration = Configuration()
        configuration.variants = .auto
        return configuration
    }
}
