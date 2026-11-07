import ArgumentParser
import Configuration
import Foundation
@testable import Frontend
import Shared
import XCTest

final class ExitCodesTest: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("outskirts-exit-codes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    // MARK: - Default

    func testTheDefaultContractIsV1() {
        XCTAssertEqual(ExitCodes.default, .v1)
        XCTAssertEqual(Configuration().exitCodes, .v1)
    }

    func testV1ExitsWithStatusOneForEveryFailureClass() {
        for failureClass in [FailureClass.findings, .configuration, .project] {
            XCTAssertEqual(failureClass.exitStatus(for: .v1), EXIT_FAILURE, "\(failureClass)")
        }
    }

    func testV2GivesEachFailureClassItsOwnStatus() {
        XCTAssertEqual(FailureClass.findings.exitStatus(for: .v2), 1)
        XCTAssertEqual(FailureClass.configuration.exitStatus(for: .v2), 2)
        XCTAssertEqual(FailureClass.project.exitStatus(for: .v2), 3)
    }

    // MARK: - One case per row

    func testFindingsWithStrictExitWithStatusOneInBothModes() {
        assertStatus(of: PeripheryError.foundIssues(count: 6), v1: 1, v2: 1)
        assertStatus(of: PeripheryError.staleBaselineEntries(count: 2), v1: 1, v2: 1)
    }

    func testMalformedConfigurationFileIsAConfigurationError() throws {
        let path = directory.appendingPathComponent(".outskirts.yml")
        try "strict: [\n".write(to: path, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try Configuration().load(from: .init(path.path)) { _ in }) { error in
            self.assertStatus(of: error, v1: 1, v2: 2)
        }
    }

    func testConfigurationThatIsNotAMappingIsAConfigurationError() throws {
        let path = directory.appendingPathComponent(".outskirts.yml")
        try "- strict\n".write(to: path, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try Configuration().load(from: .init(path.path)) { _ in }) { error in
            self.assertStatus(of: error, v1: 1, v2: 2)
        }
    }

    func testInvalidVersion2FileIsAConfigurationError() throws {
        let path = directory.appendingPathComponent(".outskirts.yml")
        try "version: 2\nretain: {pubic: true}\n".write(to: path, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try Configuration().load(from: .init(path.path)) { _ in }) { error in
            self.assertStatus(of: error, v1: 1, v2: 2)
        }
    }

    func testInvalidVersion2FileStopsTheScanBeforeTheBuild() throws {
        let path = directory.appendingPathComponent(".outskirts.yml")
        try "version: 2\nreport: {exit_codes: v2, strict: maybe}\nretain: {pubic: true}\n".write(to: path, atomically: true, encoding: .utf8)
        let command = try ScanCommand.parse(["--project-root", directory.path])
        let currentDirectory = FileManager.default.currentDirectoryPath
        defer {
            FileManager.default.changeCurrentDirectoryPath(currentDirectory)
            ExitCodes.selected = .default
        }

        // The configuration is loaded before the Swift toolchain is asked for its version and the project is set up.
        XCTAssertThrowsError(try command.prepareScan()) { error in
            XCTAssertEqual((error as? ConfigurationFileError)?.problems.count, 2, "\(error)")
        }
        // The file's own valid `exit_codes` applies to its failure.
        XCTAssertEqual(ExitCodes.selected, .v2)
    }

    func testExitCodesOptionAppliesToAnInvalidVersion2File() throws {
        let path = directory.appendingPathComponent(".outskirts.yml")
        try "version: 2\nreport: {exit_codes: v2}\nretain: {pubic: true}\n".write(to: path, atomically: true, encoding: .utf8)
        let command = try ScanCommand.parse(["--project-root", directory.path, "--exit-codes", "v1"])
        let currentDirectory = FileManager.default.currentDirectoryPath
        defer {
            FileManager.default.changeCurrentDirectoryPath(currentDirectory)
            ExitCodes.selected = .default
        }

        XCTAssertThrowsError(try command.prepareScan())
        XCTAssertEqual(ExitCodes.selected, .v1)
    }

    func testMissingConfigurationFileIsAConfigurationError() {
        assertStatus(of: PeripheryError.pathDoesNotExist(path: "missing.yml"), v1: 1, v2: 2)
    }

    func testRejectedGenericProjectConfigIsAConfigurationError() {
        assertStatus(of: PeripheryError.usageError("Invalid generic project config config.json: 'indexstores' must list at least one index store"), v1: 1, v2: 2)
    }

    func testMissingIndexStoreIsAProjectFailure() {
        assertStatus(of: PeripheryError.indexStoreNotFound(derivedDataPath: "/DerivedData"), v1: 1, v2: 3)
        assertStatus(of: PeripheryError.indexStoreNotFoundAfterSkippedBuild(tried: ["/DerivedData"]), v1: 1, v2: 3)
        assertStatus(of: PeripheryError.spmIndexStoreNotFound(tried: [".build"]), v1: 1, v2: 3)
        assertStatus(of: PeripheryError.noIndexedSourceFiles(fileCount: 1, indexStorePaths: ["/store"]), v1: 1, v2: 3)
    }

    func testFailedBuildIsAProjectFailure() {
        assertStatus(of: PeripheryError.shellCommandFailed(cmd: ["swift", "build"], status: 1, output: "error"), v1: 1, v2: 3)
        assertStatus(of: PeripheryError.buildFailed(message: "None of the variants can be built: ios."), v1: 1, v2: 3)
    }

    func testAnErrorOutsideOutskirtsIsAProjectFailure() {
        assertStatus(of: CocoaError(.fileReadCorruptFile), v1: 1, v2: 3)
    }

    func testUsageErrorsKeepTheStatusOfTheArgumentParserInBothModes() {
        XCTAssertThrowsError(try ScanCommand.parse(["--format", "nope"])) { error in
            self.assertStatus(of: error, v1: 64, v2: 64)
        }
        assertStatus(of: ValidationError("'--max-results' must be at least 1"), v1: 64, v2: 64)
    }

    func testAnExplicitExitCodeIsKeptInBothModes() {
        assertStatus(of: ExitCode.failure, v1: 1, v2: 1)
        assertStatus(of: CleanExit.message("done"), v1: 0, v2: 0)
    }

    // MARK: - Option and setting

    func testExitCodesV2InTheFileSelectsV2() throws {
        XCTAssertEqual(try merge([], file: "exit_codes: v2\n").exitCodes, .v2)
    }

    func testExitCodesOptionSelectsV2() throws {
        XCTAssertEqual(try merge(["--exit-codes", "v2"], file: nil).exitCodes, .v2)
    }

    func testExitCodesOptionOverridesTheFile() throws {
        XCTAssertEqual(try merge(["--exit-codes", "v1"], file: "exit_codes: v2\n").exitCodes, .v1)
        XCTAssertEqual(try merge(["--exit-codes", "v2"], file: "exit_codes: v1\n").exitCodes, .v2)
    }

    func testAnInvalidExitCodesOptionIsAUsageError() {
        XCTAssertThrowsError(try ScanCommand.parse(["--exit-codes", "v3"])) { error in
            XCTAssertEqual(ScanCommand.exitCode(for: error).rawValue, 64)
        }
    }

    // MARK: - Private

    private func assertStatus(of error: Error, v1: Int32, v2: Int32, file: StaticString = #filePath, line: UInt = #line) {
        let parserCode = ScanCommand.exitCode(for: error).rawValue
        XCTAssertEqual(ExitStatus.code(for: error, parserCode: parserCode, mode: .v1), v1, "v1: \(error)", file: file, line: line)
        XCTAssertEqual(ExitStatus.code(for: error, parserCode: parserCode, mode: .v2), v2, "v2: \(error)", file: file, line: line)
    }

    private func merge(_ arguments: [String], file: String?) throws -> Configuration {
        let command = try ScanCommand.parse(arguments)
        let configuration = Configuration()

        if let file {
            let path = directory.appendingPathComponent("outskirts-\(UUID().uuidString).yml")
            try file.write(to: path, atomically: true, encoding: .utf8)
            try configuration.load(from: .init(path.path)) { XCTFail("Unexpected warning \($0)") }
        }

        command.apply(to: configuration)
        return configuration
    }
}
