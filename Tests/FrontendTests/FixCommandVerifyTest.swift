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
        XCTAssertThrowsError(try FixCommand.verifyBuild(of: pendingFixes, driver: driver, projectKind: .spm, configuration: Configuration(), logger: logger)) { error in
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

        try FixCommand.verifyBuild(of: pendingFixes, driver: Driver {}, projectKind: .spm, configuration: Configuration(), logger: logger)
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

    // MARK: - Rebuilt builds

    func testVerifyMessageListsTheRebuiltConfigurationsAndVariants() {
        XCTAssertEqual(
            FixCommand.rebuiltBuilds(of: .spm, configuration: Configuration(), builtVariants: []),
            "Rebuilt: the debug configuration, for the default platform. Other configurations (such as release), platforms and compilation conditions were not rebuilt: build them before shipping the fixes."
        )

        let release = Configuration()
        release.buildArguments = ["-Xswiftc", "-DFEATURE", "--configuration", "release"]
        XCTAssertTrue(
            FixCommand.rebuiltBuilds(of: .spm, configuration: release, builtVariants: ["arm64-apple-macosx15.0", "x86_64-unknown-linux-gnu,configuration=debug"])
                .hasPrefix("Rebuilt: the variants arm64-apple-macosx15.0; x86_64-unknown-linux-gnu,configuration=debug, in the release configuration unless the variant names its own, with the build arguments of the scan. Other configurations")
        )

        let xcode = Configuration()
        xcode.schemes = ["App", "Widget"]
        XCTAssertTrue(
            FixCommand.rebuiltBuilds(of: .xcode(projectPath: "App.xcodeproj"), configuration: xcode, builtVariants: [])
                .hasPrefix("Rebuilt: the configuration of the Test action of 'App', 'Widget' (Debug by default), for the default platform.")
        )

        xcode.buildArguments = ["-configuration", "Staging"]
        XCTAssertTrue(FixCommand.rebuiltBuilds(of: .xcode(projectPath: "App.xcodeproj"), configuration: xcode, builtVariants: []).hasPrefix("Rebuilt: the Staging configuration,"))
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
