import Foundation
@testable import TestShared
import XCTest

/// Runs the `outskirts` executable and pins the warnings of `--no-color` and `--index-store-path`.
final class DeprecationWarningsEndToEndTest: XCTestCase {
    private static let noColorWarning = "The '--no-color' option is deprecated, use '--color never' instead."
    private static let xcodeWarning = "When using the '--index-store-path' option please ensure that Xcode is not running. False-positives can occur if Xcode writes to the index store while outskirts is running."
    private static let skipBuildWarning = "The '--index-store-path' option implies '--skip-build', specify it to silence this warning."

    private var directory: URL!
    private var missingStore: String {
        directory.appendingPathComponent(".build/debug/index/store").path
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("outskirts-deprecations-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("Sources/Fixture"), withIntermediateDirectories: true)
        try """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "Fixture", targets: [.target(name: "Fixture")])
        """.write(to: directory.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try "struct UnusedFixtureType {}\n".write(to: directory.appendingPathComponent("Sources/Fixture/Fixture.swift"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    func testDefaultIndexStoreScanPrintsBothWarningsInOrder() throws {
        let stderr = try run(["scan", "--index-store-path", missingStore, "--color", "never"])

        XCTAssertEqual(warnings(in: stderr), [Self.xcodeWarning, Self.skipBuildWarning], stderr)
    }

    func testNoColorPrintsOneDeprecationWarningAndDisablesColor() throws {
        let stderr = try run(["scan", "--index-store-path", missingStore, "--no-color"])

        XCTAssertEqual(warnings(in: stderr), [Self.noColorWarning, Self.xcodeWarning, Self.skipBuildWarning], stderr)
        XCTAssertFalse(stderr.contains("\u{1B}["), stderr)
    }

    func testQuietIndexStoreWithASwiftPMStorePrintsNoWarning() throws {
        let stderr = try run(["scan", "--index-store-path", missingStore, "--quiet-index-store", "--color", "never"])

        XCTAssertEqual(warnings(in: stderr), [], stderr)
    }

    func testQuietIndexStoreFromTheConfigurationFile() throws {
        try "quiet_index_store: true\n".write(to: directory.appendingPathComponent(".outskirts.yml"), atomically: true, encoding: .utf8)

        let stderr = try run(["scan", "--index-store-path", missingStore, "--color", "never"])

        XCTAssertEqual(warnings(in: stderr), [], stderr)
    }

    // MARK: - Private

    private func warnings(in stderr: String) -> [String] {
        stderr.split(separator: "\n").compactMap { line in
            line.hasPrefix("warning: ") ? String(line.dropFirst("warning: ".count)) : nil
        }
    }

    private func run(_ arguments: [String]) throws -> String {
        let stderrFile = directory.appendingPathComponent("stderr.txt")
        FileManager.default.createFile(atPath: stderrFile.path, contents: nil)

        let exited = DispatchSemaphore(value: 0)
        let process = Process()
        process.executableURL = try locatePeripheryExecutable(near: Self.self)
        process.arguments = arguments + ["--disable-update-check"]
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = try FileHandle(forWritingTo: stderrFile)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()

        if exited.wait(timeout: .now() + 300) == .timedOut {
            kill(process.processIdentifier, SIGKILL)
            XCTFail("outskirts did not exit within 300s")
        }

        return try String(contentsOf: stderrFile, encoding: .utf8)
    }
}
