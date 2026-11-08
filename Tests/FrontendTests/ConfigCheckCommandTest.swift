import Configuration
import Foundation
@testable import TestShared
import XCTest

/// Runs `outskirts config check`, `migrate` and `print` on configuration files written to a temporary directory.
final class ConfigCheckCommandTest: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("outskirts-config-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
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

    func testVersion2FileReportsTheProblemsOfTheLoad() throws {
        try write(".outskirts.yml", "version: 2\nretain: {pubic: true}\nreport:\n  strict: maybe\n  skip_stdout: true\n")

        let output = try check([])

        var loadProblems: [String] = []
        do {
            try Configuration().load(from: .init(directory.appendingPathComponent(".outskirts.yml").path)) { _ in }
        } catch let error as ConfigurationFileError {
            loadProblems = error.problems
        }
        let reported = output.stderr.split(separator: "\n").map(String.init).filter { $0.hasPrefix("error: ") && !$0.hasSuffix("found") }

        XCTAssertEqual(output.status, 1)
        XCTAssertEqual(loadProblems.count, 2)
        XCTAssertEqual(reported.map(Self.locatedMessage), loadProblems.map(Self.locatedMessage), output.stderr)
        XCTAssertTrue(output.stderr.contains(".outskirts.yml: 2 problems found"), output.stderr)
        XCTAssertFalse(output.stderr.contains("skip-stdout-results"), output.stderr)
    }

    func testMissingFileExitsOne() throws {
        let given = try check(["--config", "missing.yml"])
        XCTAssertEqual(given.status, 1)
        XCTAssertTrue(given.stderr.contains("missing.yml"), given.stderr)

        let none = try check([])
        XCTAssertEqual(none.status, 1)
        XCTAssertTrue(none.stderr.contains("No configuration file"), none.stderr)
    }

    func testSkipStdoutResultsWithoutWriteResultsExitsOneWithTheScanError() throws {
        try write(".outskirts.yml", "skip_stdout_results: true\n")

        let output = try check([])

        XCTAssertEqual(output.status, 1)
        XCTAssertTrue(output.stderr.contains("error: The '--skip-stdout-results' option requires '--write-results', otherwise the results would not be output anywhere."), output.stderr)
    }

    func testChangedLinesWithoutChangedSinceExitsOneWithTheScanError() throws {
        try write(".outskirts.yml", "changed_lines: true\n")

        let output = try check([])

        XCTAssertEqual(output.status, 1)
        XCTAssertTrue(output.stderr.contains("error: The '--changed-lines' option requires '--changed-since', otherwise there is nothing to compare the lines with."), output.stderr)
    }

    func testVariantsFormsAreAccepted() throws {
        try write(".outskirts.yml", "variants:\n  - arm64-apple-macosx15.0\n  - triple: arm64-apple-ios18.0-simulator\n    sdk: iphonesimulator\n")
        XCTAssertEqual(try check([]).status, 0)

        try write(".outskirts.yml", "variants: auto\n")
        XCTAssertEqual(try check([]).status, 0)
    }

    func testInvalidVariantsExitOneWithTheExpectedForms() throws {
        try write(".outskirts.yml", "variants: [default, arm64-apple-macosx15.0]\n")

        let output = try check([])

        XCTAssertEqual(output.status, 1)
        XCTAssertEqual(output.warnings.count, 1, output.stderr)
        XCTAssertTrue(output.warnings.first?.contains("'variants' expects 'default', 'auto', or a list of") == true, output.stderr)
    }

    func testVariantsWithIndexStorePathExitOneWithTheScanError() throws {
        try write(".outskirts.yml", "variants: auto\nindex_store_path: [.build/index]\n")

        let output = try check([])

        XCTAssertEqual(output.status, 1)
        XCTAssertTrue(output.stderr.contains("cannot be combined with '--index-store-path'"), output.stderr)
    }

    func testEveryUsageErrorIsReported() throws {
        try write(".outskirts.yml", "skip_stdout_results: true\nchanged_lines: true\nstrict_baseline: true\n")

        let output = try check([])

        XCTAssertEqual(output.status, 1)
        XCTAssertTrue(output.stderr.contains(".outskirts.yml: 3 problems found"), output.stderr)
    }

    func testMigratePrintsTheV2FileAndApplyWritesIt() throws {
        let v1 = "# Header.\n\n# Gate.\nstrict: true\ndisable_unused_import_analysis: true\n"
        try write(".outskirts.yml", v1)

        let printed = try run(["config", "migrate"], [])

        XCTAssertEqual(printed.status, 0, printed.stderr)
        XCTAssertTrue(printed.stdout.contains("version: 2\nexclude:\n"), printed.stdout)
        XCTAssertTrue(printed.stdout.contains("rules:\n  unused-import: off\n"), printed.stdout)
        XCTAssertTrue(printed.stdout.contains("report:\n  # Gate.\n  strict: true\n"), printed.stdout)
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent(".outskirts.yml"), encoding: .utf8), v1, "the file is untouched without --apply")

        let applied = try run(["config", "migrate"], ["--apply"])

        XCTAssertEqual(applied.status, 0, applied.stderr)
        XCTAssertEqual(applied.stdout, "")
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent(".outskirts.yml"), encoding: .utf8), printed.stdout)
        XCTAssertEqual(try check([]).status, 0)
        XCTAssertNotEqual(try run(["config", "migrate"], []).status, 0, "a v2 file is not migrated again")
    }

    func testPrintShowsTheEffectiveConfiguration() throws {
        try write(".outskirts.yml", "version: 2\nreport: {strict: true}\noverrides:\n  - modules: [Kit]\n    retain: {public: true}\n")

        let output = try run(["config", "print"], [])

        XCTAssertEqual(output.status, 0, output.stderr)
        XCTAssertTrue(output.stdout.hasSuffix("version: 2\nreport:\n  strict: true\noverrides:\n- modules: [Kit]\n  retain: {public: true}\n"), output.stdout)
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

    /// The line, column and message of a problem, without the file path, which is relative for the command.
    private static func locatedMessage(_ problem: String) -> String {
        problem.components(separatedBy: ".outskirts.yml:").last ?? problem
    }

    private func write(_ name: String, _ contents: String) throws {
        try contents.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func check(_ arguments: [String]) throws -> Output {
        try run(["config", "check"], arguments)
    }

    private func run(_ command: [String], _ arguments: [String]) throws -> Output {
        let stdoutFile = directory.appendingPathComponent("stdout.txt")
        let stderrFile = directory.appendingPathComponent("stderr.txt")
        FileManager.default.createFile(atPath: stdoutFile.path, contents: nil)
        FileManager.default.createFile(atPath: stderrFile.path, contents: nil)
        defer {
            try? FileManager.default.removeItem(at: stdoutFile)
            try? FileManager.default.removeItem(at: stderrFile)
        }

        let process = Process()
        process.executableURL = try locatePeripheryExecutable(near: Self.self)
        process.arguments = command + ["--project-root", directory.path] + arguments
        process.standardOutput = try FileHandle(forWritingTo: stdoutFile)
        process.standardError = try FileHandle(forWritingTo: stderrFile)
        try process.run()
        process.waitUntilExit()

        return try Output(
            status: process.terminationStatus,
            stdout: String(contentsOf: stdoutFile, encoding: .utf8),
            stderr: String(contentsOf: stderrFile, encoding: .utf8)
        )
    }
}
