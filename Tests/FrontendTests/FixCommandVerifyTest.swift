import Configuration
@testable import Fix
import Foundation
@testable import Frontend
import Logger
import ProjectDrivers
import Shared
import SystemPackage
import XCTest

/// What `fix --apply --verify` does with the fixes it wrote, when the build is cancelled.
final class FixCommandVerifyTest: XCTestCase {
    private var directory: FilePath!
    private let logger = Logger(quiet: true, verbose: false, colorMode: .never)

    override func setUpWithError() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("outskirts-fix-verify-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        directory = FilePath(url.path)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    }

    func testCancellationDuringVerify_restoresOriginals() throws {
        let (plan, files) = try writtenPlan()
        let pendingFixes = PendingFixes(projectRoot: directory, logger: logger)
        try pendingFixes.apply(plan)
        XCTAssertEqual(try contents(of: files), ["fixed A", "fixed B"])

        // The signal handler runs the cancellation hook while the build runs, then stops the build.
        let driver = Driver {
            pendingFixes.cancel()
            throw PeripheryError.shellCommandKilled(cmd: ["swift", "build"], signal: SIGINT, output: "")
        }
        XCTAssertThrowsError(try FixCommand.verifyBuild(of: pendingFixes, driver: driver, configuration: Configuration(), logger: logger)) { error in
            guard case PeripheryError.shellCommandKilled = error else {
                return XCTFail("Expected the error of the cancelled build, received \(error)")
            }
        }

        XCTAssertEqual(try contents(of: files), ["original A", "original B"])
        XCTAssertNil(pendingFixes.restore(), "the files are only restored once")
    }

    func testCancellationAfterTheFixesAreKept_leavesThem() throws {
        let (plan, files) = try writtenPlan()
        let pendingFixes = PendingFixes(projectRoot: directory, logger: logger)
        try pendingFixes.apply(plan)

        try FixCommand.verifyBuild(of: pendingFixes, driver: Driver {}, configuration: Configuration(), logger: logger)
        pendingFixes.keep()
        pendingFixes.cancel()

        XCTAssertEqual(try contents(of: files), ["fixed A", "fixed B"])
    }

    func testCancellationSummaryListsTheRestoredFiles() throws {
        let (plan, _) = try writtenPlan()
        let pendingFixes = PendingFixes(projectRoot: directory, logger: logger)
        try pendingFixes.apply(plan)

        let restoration = try XCTUnwrap(pendingFixes.restore())

        XCTAssertEqual(restoration.cancellationSummary, "Cancelled before the fixes were kept, restored 2 of 2 files:\n  restored A.swift\n  restored B.swift")
    }

    // MARK: - Private

    private struct Driver: ProjectDriver {
        let onBuild: () throws -> Void

        func build() throws {
            try onBuild()
        }
    }

    private func writtenPlan() throws -> (FixPlan, [FilePath]) {
        var plan = FixPlan()
        var files: [FilePath] = []
        for name in ["A", "B"] {
            let file = directory.appending("\(name).swift")
            try Data("original \(name)".utf8).write(to: URL(fileURLWithPath: file.string))
            plan.changes.append(.init(path: file, original: Array("original \(name)".utf8), fixed: Array("fixed \(name)".utf8)))
            files.append(file)
        }
        return (plan, files)
    }

    private func contents(of files: [FilePath]) throws -> [String] {
        try files.map { try String(contentsOfFile: $0.string, encoding: .utf8) }
    }
}
