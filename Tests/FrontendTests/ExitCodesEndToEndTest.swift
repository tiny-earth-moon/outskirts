import Foundation
@testable import TestShared
import XCTest

/// Runs the `outskirts` executable and checks the exit status of each row of the exit status tables, in both modes.
final class ExitCodesEndToEndTest: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("outskirts-exit-codes-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    func testCleanScanExitsWithZeroInBothModes() throws {
        try writePackage(source: "public struct UsedFixtureType {}\n")

        for mode in ["v1", "v2"] {
            let output = try run(["scan", "--strict", "--retain-public", "--exit-codes", mode])
            XCTAssertEqual(output.status, 0, "\(mode): \(output.stderr)")
        }
    }

    func testFindingsWithStrictExitWithOneInBothModes() throws {
        try writePackage(source: "struct UnusedFixtureType {}\n")

        let v1 = try run(["scan", "--strict"])
        let v2 = try run(["scan", "--strict", "--exit-codes", "v2"])

        XCTAssertEqual(v1.status, 1, v1.stderr)
        XCTAssertEqual(v2.status, 1, v2.stderr)
        XCTAssertTrue(v2.stderr.contains("Found 1 issue."), v2.stderr)
    }

    func testFailedBuildExitsWithThreeInV2() throws {
        try writePackage(source: "struct Broken {\n")

        let v1 = try run(["scan"])
        let v2 = try run(["scan", "--exit-codes", "v2"])

        XCTAssertEqual(v1.status, 1, v1.stderr)
        XCTAssertEqual(v2.status, 3, v2.stderr)
    }

    func testMissingIndexStoreExitsWithThreeInV2() throws {
        try writePackage(source: "struct UnusedFixtureType {}\n")
        let missing = directory.appendingPathComponent("missing-index-store").path

        let v1 = try run(["scan", "--index-store-path", missing])
        let v2 = try run(["scan", "--index-store-path", missing, "--exit-codes", "v2"])

        XCTAssertEqual(v1.status, 1, v1.stderr)
        XCTAssertEqual(v2.status, 3, v2.stderr)
        XCTAssertEqual(v1.stderr, v2.stderr)
    }

    func testMalformedConfigurationExitsWithTwoOnlyWithTheOption() throws {
        try write("strict: [\nexit_codes: v2\n", to: ".outskirts.yml")

        let v1 = try run(["scan"])
        let v2 = try run(["scan", "--exit-codes", "v2"])

        XCTAssertEqual(v1.status, 1, "exit_codes cannot be read from a malformed file: \(v1.stderr)")
        XCTAssertEqual(v2.status, 2, v2.stderr)
        XCTAssertEqual(v1.stderr, v2.stderr)
        XCTAssertEqual(v1.stdout, v2.stdout)
    }

    func testRejectedGenericProjectConfigExitsWithTwoInV2() throws {
        try write("{}\n", to: "project.json")
        let arguments = ["scan", "--generic-project-config", "project.json"]

        let v1 = try run(arguments)
        let v2 = try run(arguments + ["--exit-codes", "v2"])

        XCTAssertEqual(v1.status, 1, v1.stderr)
        XCTAssertEqual(v2.status, 2, v2.stderr)
        XCTAssertTrue(v1.stderr.contains("Invalid generic project config"), v1.stderr)
        XCTAssertEqual(v1.stderr, v2.stderr)
        XCTAssertEqual(v1.stdout, v2.stdout)
    }

    func testExitCodesInTheFileBehavesLikeTheOptionAndTheOptionOverridesIt() throws {
        try write("{}\n", to: "project.json")
        try write("exit_codes: v2\n", to: ".outskirts.yml")
        let arguments = ["scan", "--generic-project-config", "project.json"]

        XCTAssertEqual(try run(arguments).status, 2)
        XCTAssertEqual(try run(arguments + ["--exit-codes", "v1"]).status, 1)
    }

    func testUsageErrorExitsWith64InBothModes() throws {
        XCTAssertEqual(try run(["scan", "--format", "nope"]).status, 64)
        XCTAssertEqual(try run(["scan", "--format", "nope", "--exit-codes", "v2"]).status, 64)
    }

    // MARK: - Private

    private struct Output {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    private func writePackage(source: String) throws {
        try write("""
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "Fixture", targets: [.target(name: "Fixture")])
        """, to: "Package.swift")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("Sources/Fixture"), withIntermediateDirectories: true)
        try write(source, to: "Sources/Fixture/Fixture.swift")
    }

    private func write(_ contents: String, to path: String) throws {
        try contents.write(to: directory.appendingPathComponent(path), atomically: true, encoding: .utf8)
    }

    private func run(_ arguments: [String]) throws -> Output {
        let stdoutFile = directory.appendingPathComponent("stdout.txt")
        let stderrFile = directory.appendingPathComponent("stderr.txt")
        FileManager.default.createFile(atPath: stdoutFile.path, contents: nil)
        FileManager.default.createFile(atPath: stderrFile.path, contents: nil)

        let exited = DispatchSemaphore(value: 0)
        let process = Process()
        process.executableURL = try locatePeripheryExecutable(near: Self.self)
        process.arguments = arguments + ["--disable-update-check"]
        process.currentDirectoryURL = directory
        process.standardOutput = try FileHandle(forWritingTo: stdoutFile)
        process.standardError = try FileHandle(forWritingTo: stderrFile)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()

        if exited.wait(timeout: .now() + 300) == .timedOut {
            kill(process.processIdentifier, SIGKILL)
            XCTFail("outskirts did not exit within 300s")
        }

        return try Output(
            status: process.terminationStatus,
            stdout: String(contentsOf: stdoutFile, encoding: .utf8),
            stderr: String(contentsOf: stderrFile, encoding: .utf8)
        )
    }
}
