import Configuration
@testable import Frontend
import Logger
import SystemPackage
import XCTest

final class ScanPreflightTest: XCTestCase {
    private let logger = Logger(quiet: true, verbose: false, colorMode: .never)

    private func relativeResults(afterPreflightWith format: OutputFormat, relativeResults: Bool = false) -> Bool {
        let configuration = Configuration()
        configuration.outputFormat = format
        configuration.relativeResults = relativeResults
        ScanPreflight.applyOutputFormatRequirements(to: configuration, logger: logger)
        return configuration.relativeResults
    }

    func testOutputFormatRequirements_forceRelativeResultsForTheFormatsThatNeedThem() {
        for format in [OutputFormat.githubActions, .gitlabCodeQuality, .codeclimate] {
            XCTAssertTrue(relativeResults(afterPreflightWith: format), "\(format)")
        }
    }

    func testOutputFormatRequirements_leaveTheOtherFormatsAlone() {
        for format in [OutputFormat.xcode, .csv, .json, .checkstyle, .githubMarkdown] {
            XCTAssertFalse(relativeResults(afterPreflightWith: format), "\(format)")
        }
    }

    func testOutputFormatRequirements_keepAnExplicitRelativeResults() {
        XCTAssertTrue(relativeResults(afterPreflightWith: .xcode, relativeResults: true))
        XCTAssertTrue(relativeResults(afterPreflightWith: .githubActions, relativeResults: true))
    }

    // MARK: - Ignored options

    private func warnings(format: OutputFormat = .xcode, relativeResults: Bool = false, relativeTo: String? = nil) -> [String] {
        let configuration = Configuration()
        configuration.outputFormat = format
        configuration.relativeResults = relativeResults
        configuration.relativeResultsBase = relativeTo.map { FilePath($0) }
        ScanPreflight.applyOutputFormatRequirements(to: configuration, logger: logger)
        return ScanPreflight.ignoredOptionWarnings(of: configuration)
    }

    func testRelativeToWithoutRelativeResultsIsReportedAsIgnored() {
        let warnings = warnings(format: .json, relativeTo: "/base")

        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings.first?.contains("'--relative-to' only applies to relative result paths") == true, "\(warnings)")
    }

    func testRelativeToWithRelativeResultsOrAFormatThatNeedsThemIsNotReported() {
        XCTAssertEqual(warnings(relativeResults: true, relativeTo: "/base"), [])
        XCTAssertEqual(warnings(format: .githubActions, relativeTo: "/base"), [])
        XCTAssertEqual(warnings(), [])
    }

    func testProjectAndGenericProjectConfigTogetherReportTheOneThatIsUsed() {
        let configuration = Configuration()
        configuration.project = "App.xcodeproj"
        configuration.genericProjectConfig = "generic.json"

        XCTAssertEqual(ScanPreflight.ignoredOptionWarnings(of: configuration), [
            "Both '--project' and '--generic-project-config' are given; scanning the Xcode project 'App.xcodeproj' and ignoring '--generic-project-config'.",
        ])

        configuration.project = nil
        XCTAssertEqual(ScanPreflight.ignoredOptionWarnings(of: configuration), [])
    }
}
