import Foundation
@testable import TestShared
import XCTest

/// Runs `outskirts config check` on configuration files written to a temporary directory.
final class ConfigCheckCommandTest: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = try makeTemporaryDirectory("outskirts-config-check")
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    func testValidFileExitsZeroAndPrintsOk() throws {
        try write(".outskirts.yml", "strict: true\nformat: json\nreport_exclude:\n  - path: Generated/**\n    kinds: [unused.function]\n")

        let output = try check([])

        XCTAssertEqual(output.status, 0, output.stderr)
        XCTAssertEqual(output.stdout, ".outskirts.yml: ok\n")
        XCTAssertEqual(output.stderr, "")
    }

    func testUnknownKeyExitsOneWithTheSuggestion() throws {
        try write("custom.yml", "retain_pubic: true\n")

        let output = try check(["--config", "custom.yml"])

        XCTAssertEqual(output.status, 1)
        XCTAssertEqual(output.warnings, ["warning: custom.yml: invalid key 'retain_pubic' (did you mean 'retain_public'?)"])
        XCTAssertTrue(output.stderr.contains("custom.yml: 1 problem found"), output.stderr)
    }

    func testWrongTypeExitsOneWithTheTypeMessage() throws {
        try write(".periphery.yml", "strict: 1\n")

        let output = try check([])

        XCTAssertEqual(output.status, 1)
        XCTAssertEqual(output.warnings, ["warning: .periphery.yml: 'strict' expects a boolean, got the integer 1"])
    }

    func testUnknownReportExcludeKindExitsOneWithTheScanError() throws {
        try write(".outskirts.yml", "report_exclude:\n  - path: Sources/**\n    kinds: [unsed]\n")

        let output = try check([])

        XCTAssertEqual(output.status, 1)
        XCTAssertTrue(output.stderr.contains("error: report_exclude: unknown result kind 'unsed' for 'Sources/**'"), output.stderr)
    }

    func testUnknownKindInTheCompactReportExcludeFormExitsOne() throws {
        try write(".outskirts.yml", "report_exclude:\n  - \"**/x.swift:unused.function,bogus\"\n")

        let output = try check([])

        XCTAssertEqual(output.status, 1)
        XCTAssertTrue(output.stderr.contains("error: report_exclude: unknown result kind 'bogus' for '**/x.swift'"), output.stderr)
    }

    func testMissingFileExitsOne() throws {
        let given = try check(["--config", "missing.yml"])
        XCTAssertEqual(given.status, 1)
        XCTAssertTrue(given.stderr.contains("missing.yml"), given.stderr)

        let none = try check([])
        XCTAssertEqual(none.status, 1)
        XCTAssertTrue(none.stderr.contains("No configuration file"), none.stderr)
    }

    // MARK: - Private

    private struct Output {
        let status: Int32
        let stdout: String
        let stderr: String

        var warnings: [String] {
            stderr.split(separator: "\n").map(String.init).filter { $0.hasPrefix("warning: ") }
        }
    }

    private func write(_ name: String, _ contents: String) throws {
        try writeFile(contents, named: name, in: directory)
    }

    func testOptionCombinationsTheScanRejectsExitOne() throws {
        for (contents, message) in [
            ("skip_stdout_results: true\n", "requires '--write-results'"),
            ("changed_lines: true\n", "requires '--changed-since'"),
            ("cache_max_age_days: -1\n", "'cache_max_age_days' setting must be 0 or more"),
            ("cache_max_size_gb: -1\n", "'cache_max_size_gb' setting must be 0 or more"),
        ] {
            try write(".outskirts.yml", contents)

            let output = try check([])

            XCTAssertEqual(output.status, 1, contents)
            XCTAssertTrue(output.stderr.contains(message), output.stderr)
        }
    }

    private func check(_ arguments: [String]) throws -> Output {
        let output = try runCapturingOutput(
            locatePeripheryExecutable(near: Self.self),
            ["config", "check", "--project-root", directory.path] + arguments,
            outputDirectory: directory
        )
        return try Output(
            status: output.status,
            stdout: XCTUnwrap(String(data: output.stdout, encoding: .utf8)),
            stderr: XCTUnwrap(String(data: output.stderr, encoding: .utf8))
        )
    }
}
