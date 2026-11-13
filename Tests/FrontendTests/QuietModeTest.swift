import Foundation
@testable import TestShared
import XCTest

/// Runs the `outskirts` executable on two small packages, one with a result and one without,
/// and checks what `--quiet` leaves on stdout.
final class QuietModeTest: XCTestCase {
    private static let packageWithResult = Result { try makePackage(source: "struct UnusedFixtureType {}\n") }
    private static let packageWithoutResult = Result { try makePackage(source: "public struct PublicFixtureType {}\n") }
    private static let packageWithInvalidConfiguration = Result {
        try makePackage(source: "public struct PublicFixtureType {}\n", configuration: "not_a_setting: 1\n")
    }

    private var outputDirectory: URL!

    // swiftlint:disable:next static_over_final_class
    override class func tearDown() {
        for package in [packageWithResult, packageWithoutResult, packageWithInvalidConfiguration] {
            if let url = try? package.get() {
                try? FileManager.default.removeItem(at: url)
            }
        }

        super.tearDown()
    }

    override func setUpWithError() throws {
        outputDirectory = try makeTemporaryDirectory("periphery-quiet-output")
        addTeardownBlock { [outputDirectory] in
            if let outputDirectory {
                try? FileManager.default.removeItem(at: outputDirectory)
            }
        }
    }

    func testMaxResultsOutsideTheAgentFormatIsReportedAsIgnored() throws {
        let output = try scan(["--format", "json", "--retain-public", "--max-results", "3"], in: Self.packageWithoutResult)

        XCTAssertEqual(output.status, 0, output.stderrText)
        XCTAssertTrue(output.stderrText.contains("'--max-results' only applies to '--format agent'"), output.stderrText)
    }

    func testQuietWithNoResultPrintsNothingInXcodeFormat() throws {
        let output = try scan(["--format", "xcode", "--retain-public", "--quiet"], in: Self.packageWithoutResult)

        XCTAssertEqual(output.status, 0, output.stderrText)
        XCTAssertEqual(output.stdoutText, "")
    }

    func testQuietWithNoResultPrintsNothingInGitHubMarkdownFormat() throws {
        let output = try scan(["--format", "github-markdown", "--retain-public", "--quiet"], in: Self.packageWithoutResult)

        XCTAssertEqual(output.status, 0, output.stderrText)
        XCTAssertEqual(output.stdoutText, "")
    }

    func testQuietWithNoResultPrintsNothingInJsonFormat() throws {
        let output = try scan(["--format", "json", "--retain-public", "--quiet"], in: Self.packageWithoutResult)

        XCTAssertEqual(output.status, 0, output.stderrText)
        XCTAssertEqual(output.stdoutText, "")
    }

    func testQuietWithNoResultStillWritesTheEmptyJsonDocumentToTheResultsFile() throws {
        let report = outputDirectory.appendingPathComponent("report.json")

        let output = try scan(["--format", "json", "--retain-public", "--quiet", "--write-results", report.path], in: Self.packageWithoutResult)

        XCTAssertEqual(output.status, 0, output.stderrText)
        XCTAssertEqual(output.stdoutText, "")
        XCTAssertEqual(try reports(in: Data(contentsOf: report)).count, 0)
    }

    func testQuietWithWriteResultsPrintsNothingToStdoutAndWritesTheCompleteFile() throws {
        let report = outputDirectory.appendingPathComponent("report.json")

        let output = try scan(["--format", "json", "--quiet", "--write-results", report.path], in: Self.packageWithResult)

        XCTAssertEqual(output.status, 0, output.stderrText)
        XCTAssertEqual(output.stdoutText, "")
        XCTAssertTrue(try reports(in: Data(contentsOf: report)).contains { $0["name"] as? String == "UnusedFixtureType" })
    }

    func testQuietWithResultsStillPrintsThemToStdout() throws {
        let output = try scan(["--format", "json", "--quiet"], in: Self.packageWithResult)

        XCTAssertEqual(output.status, 0, output.stderrText)
        XCTAssertTrue(try reports(in: output.stdout).contains { $0["name"] as? String == "UnusedFixtureType" }, output.stdoutText)
    }

    func testWithoutQuietTheNoResultLineIsStillPrinted() throws {
        let output = try scan(["--format", "xcode", "--retain-public"], in: Self.packageWithoutResult)

        XCTAssertEqual(output.status, 0, output.stderrText)
        XCTAssertTrue(output.stdoutText.contains("No unused code detected."), output.stdoutText)
    }

    func testWithoutQuietWriteResultsStillPrintsToStdout() throws {
        let report = outputDirectory.appendingPathComponent("report.json")

        let output = try scan(["--format", "json", "--write-results", report.path], in: Self.packageWithResult)

        XCTAssertEqual(output.status, 0, output.stderrText)
        XCTAssertTrue(try reports(in: output.stdout).contains { $0["name"] as? String == "UnusedFixtureType" }, output.stdoutText)
    }

    func testStrictWithResultsExitsWithOneEvenWhenQuiet() throws {
        let report = outputDirectory.appendingPathComponent("report.json")

        let output = try scan(["--format", "json", "--quiet", "--strict", "--write-results", report.path], in: Self.packageWithResult)

        XCTAssertEqual(output.status, 1, output.stderrText)
        XCTAssertEqual(output.stdoutText, "")
    }

    func testStrictWithoutResultsExitsWithZeroWhenQuiet() throws {
        let output = try scan(["--quiet", "--strict", "--retain-public"], in: Self.packageWithoutResult)

        XCTAssertEqual(output.status, 0, output.stderrText)
        XCTAssertEqual(output.stdoutText, "")
    }

    func testQuietStillPrintsTheConfigurationWarningOnStderrOnly() throws {
        let output = try scan(["--format", "json", "--retain-public", "--quiet"], in: Self.packageWithInvalidConfiguration)

        XCTAssertEqual(output.status, 0, output.stderrText)
        XCTAssertEqual(output.stdoutText, "")
        XCTAssertTrue(output.stderrText.contains("invalid key 'not_a_setting'"), output.stderrText)
    }

    func testWithoutQuietTheConfigurationWarningIsPrintedOnStderr() throws {
        let output = try scan(["--format", "xcode", "--retain-public"], in: Self.packageWithInvalidConfiguration)

        XCTAssertEqual(output.status, 0, output.stderrText)
        XCTAssertTrue(output.stderrText.contains("not_a_setting"), output.stderrText)
    }

    // MARK: - Private

    private struct ScanOutput {
        let status: Int32
        let stdout: Data
        let stderr: Data

        var stdoutText: String {
            String(bytes: stdout, encoding: .utf8) ?? ""
        }

        var stderrText: String {
            String(bytes: stderr, encoding: .utf8) ?? ""
        }
    }

    private static func makePackage(source: String, configuration: String? = nil) throws -> URL {
        let root = uniqueTemporaryURL("periphery-quiet")
        let sources = root.appendingPathComponent("Sources/Fixture")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "Fixture", targets: [.target(name: "Fixture")])
        """.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try source.write(to: sources.appendingPathComponent("Fixture.swift"), atomically: true, encoding: .utf8)
        if let configuration {
            try configuration.write(to: root.appendingPathComponent(".outskirts.yml"), atomically: true, encoding: .utf8)
        }
        return root
    }

    private func reports(in data: Data) throws -> [[String: Any]] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [[String: Any]], "not a JSON report")
    }

    private func scan(_ arguments: [String], in package: Result<URL, Error>) throws -> ScanOutput {
        let output = try runCapturingOutput(
            locatePeripheryExecutable(near: Self.self),
            ["scan", "--disable-update-check"] + arguments,
            currentDirectoryURL: package.get(),
            outputDirectory: outputDirectory,
            timeout: (300, "outskirts")
        )
        return ScanOutput(status: output.status, stdout: output.stdout, stderr: output.stderr)
    }
}
