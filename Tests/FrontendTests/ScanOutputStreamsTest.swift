import Foundation
@testable import TestShared
import XCTest

/// Runs the `outskirts` executable on a small package and checks which stream carries what.
final class ScanOutputStreamsTest: XCTestCase {
    private static let package: Result<URL, Error> = Result {
        let root = uniqueTemporaryURL("periphery-streams")
        let sources = root.appendingPathComponent("Sources/Fixture")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "Fixture", targets: [.target(name: "Fixture")])
        """.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try "struct UnusedFixtureType {}\n".write(to: sources.appendingPathComponent("Fixture.swift"), atomically: true, encoding: .utf8)
        return root
    }

    private var outputDirectory: URL!

    // swiftlint:disable:next static_over_final_class
    override class func tearDown() {
        if let package = try? package.get() {
            try? FileManager.default.removeItem(at: package)
        }

        super.tearDown()
    }

    override func setUpWithError() throws {
        outputDirectory = try makeTemporaryDirectory("periphery-streams-output")
        addTeardownBlock { [outputDirectory] in
            if let outputDirectory {
                try? FileManager.default.removeItem(at: outputDirectory)
            }
        }
    }

    func testVerboseLogsGoToStderrSoThatJsonOnStdoutStaysParseable() throws {
        let output = try scan(["--format", "json", "--verbose"])

        XCTAssertEqual(output.status, 0, output.stderrText)
        XCTAssertTrue(try reportNames(in: output.stdout).contains("UnusedFixtureType"), output.stdoutText)
        XCTAssertTrue(output.stderrText.contains("[version]"), "verbose messages are expected on stderr:\n\(output.stderrText)")
    }

    func testSkipStdoutResultsWithWriteResultsPrintsNothingToStdout() throws {
        let report = outputDirectory.appendingPathComponent("report.json")

        let output = try scan(["--format", "json", "--verbose", "--write-results", report.path, "--skip-stdout-results"])

        XCTAssertEqual(output.status, 0, output.stderrText)
        XCTAssertEqual(output.stdoutText, "")
        XCTAssertTrue(try reportNames(in: Data(contentsOf: report)).contains("UnusedFixtureType"))
        XCTAssertTrue(output.stderrText.contains("[version]"), "verbose messages are expected on stderr:\n\(output.stderrText)")
    }

    func testWriteResultsAloneStillPrintsTheResultsToStdout() throws {
        let report = outputDirectory.appendingPathComponent("report.json")

        let output = try scan(["--format", "json", "--write-results", report.path])

        XCTAssertEqual(output.status, 0, output.stderrText)
        XCTAssertTrue(try reportNames(in: output.stdout).contains("UnusedFixtureType"), output.stdoutText)
        XCTAssertTrue(try reportNames(in: Data(contentsOf: report)).contains("UnusedFixtureType"))
    }

    func testWriteResultsFromTheConfigurationFile_isRefusedOutsideTheProjectRootButNotOnTheCommandLine() throws {
        let report = outputDirectory.appendingPathComponent("report.json")
        try Data("kept".utf8).write(to: report)
        let config = outputDirectory.appendingPathComponent("outskirts.yml")
        try "write_results: \(report.path)\n".write(to: config, atomically: true, encoding: .utf8)

        let fromFile = try scan(["--format", "json", "--config", config.path])

        XCTAssertNotEqual(fromFile.status, 0)
        XCTAssertTrue(fromFile.stderrText.contains("pass the path on the command line"), fromFile.stderrText)
        XCTAssertEqual(try String(contentsOf: report, encoding: .utf8), "kept")

        let fromCommandLine = try scan(["--format", "json", "--config", config.path, "--write-results", report.path])

        XCTAssertEqual(fromCommandLine.status, 0, fromCommandLine.stderrText)
        XCTAssertTrue(try reportNames(in: Data(contentsOf: report)).contains("UnusedFixtureType"))
    }

    func testSkipStdoutResultsWithoutWriteResultsIsAUsageError() throws {
        let output = try scan(["--format", "json", "--skip-stdout-results"])

        XCTAssertNotEqual(output.status, 0)
        XCTAssertEqual(output.stdoutText, "")
        XCTAssertTrue(output.stderrText.contains("--write-results"), output.stderrText)
    }

    func testXcodeFormatKeepsProgressAndVerboseMessagesOnStdout() throws {
        let output = try scan(["--format", "xcode", "--verbose"])

        XCTAssertEqual(output.status, 0, output.stderrText)
        XCTAssertTrue(output.stdoutText.contains("[version]"), output.stdoutText)
        XCTAssertTrue(output.stdoutText.contains("UnusedFixtureType"), output.stdoutText)
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

    private func reportNames(in data: Data) throws -> [String] {
        let report = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [[String: Any]], "stdout is not a JSON report")
        return report.compactMap { $0["name"] as? String }
    }

    private func scan(_ arguments: [String]) throws -> ScanOutput {
        let output = try runCapturingOutput(
            peripheryExecutable(),
            ["scan", "--disable-update-check"] + arguments,
            currentDirectoryURL: Self.package.get(),
            outputDirectory: outputDirectory,
            timeout: (300, "periphery")
        )
        return ScanOutput(status: output.status, stdout: output.stdout, stderr: output.stderr)
    }

    private func peripheryExecutable() throws -> URL {
        try locatePeripheryExecutable(near: Self.self)
    }
}
