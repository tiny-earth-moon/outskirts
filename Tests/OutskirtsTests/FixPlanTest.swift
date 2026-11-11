@testable import Fix
import Foundation
@testable import PeripheryKit
import Shared
import SourceGraph
import SystemPackage
import TestShared
import XCTest

final class FixPlanTest: XCTestCase {
    private var directory: URL!
    private var root: FilePath!

    private let original = "{\n  \"strings\" : {\n    \"a\" : {\n\n    },\n    \"b\" : {\n\n    }\n  },\n  \"version\" : \"1.0\"\n}"
    private let fixed = "{\n  \"strings\" : {\n    \"b\" : {\n\n    }\n  },\n  \"version\" : \"1.0\"\n}"

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = try makeTemporaryDirectory("FixPlanTest")
        root = FilePath(directory.resolvingSymlinksInPath().appendingPathComponent("Project").path)
        try FileManager.default.createDirectory(atPath: root.string, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    private func catalog(_ name: String = "Localizable.xcstrings", _ contents: String? = nil) throws -> FilePath {
        let path = root.appending(name)
        try FileManager.default.createDirectory(atPath: path.removingLastComponent().string, withIntermediateDirectories: true)
        try Data((contents ?? original).utf8).write(to: URL(fileURLWithPath: path.string))
        return path
    }

    private func planner(_ workingTree: WorkingTreeState = .ignored, scanStartedAt: Date? = nil) -> FixPlanner {
        FixPlanner(projectRoot: root, workingTree: workingTree, scanStartedAt: scanStartedAt)
    }

    private func contents(_ path: FilePath) throws -> String {
        try String(contentsOfFile: path.string, encoding: .utf8)
    }

    private func git(_ arguments: String...) throws {
        let output = try runCapturingOutput(
            URL(fileURLWithPath: "/usr/bin/env"),
            ["git", "-C", root.string, "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"] + arguments,
            outputDirectory: directory
        )
        XCTAssertEqual(output.status, 0, "git \(arguments.joined(separator: " ")): \(String(bytes: output.stderr, encoding: .utf8) ?? "?")")
    }

    private func reasons(_ plan: FixPlan) -> [String: SkipReason] {
        plan.skipped.reduce(into: [:]) { $0[$1.path.relativeTo(root).string] = $1.reason }
    }

    func testOnlyUnusedCatalogKeysAreCollectedByCatalog() {
        func result(_ name: String, _ kind: Declaration.Kind, in file: String, _ annotation: ScanResult.Annotation = .unused) -> ScanResult {
            let location = Location(file: SourceFile(path: FilePath(file), modules: []), line: 1, column: 1)
            return ScanResult(declaration: Declaration(name: name, kind: kind, usrs: ["\(file)-\(name)"], location: location), annotation: annotation)
        }

        let keys = FixPlanner.unusedCatalogKeys(in: [
            result("a", .localizedString, in: "/p/A.xcstrings"),
            result("b", .localizedString, in: "/p/A.xcstrings"),
            result("a", .localizedString, in: "/p/B.xcstrings"),
            result("c", .localizedString, in: "/p/B.xcstrings", .superfluousIgnoreCommand),
            result("f()", .functionFree, in: "/p/F.swift"),
        ])

        XCTAssertEqual(keys, [FilePath("/p/A.xcstrings"): ["a", "b"], FilePath("/p/B.xcstrings"): ["a"]])
    }

    func testDryRunDiffIsRelativeToTheRootAndLeavesTheFileUntouched() throws {
        let path = try catalog("App/Localizable.xcstrings")
        let plan = planner().plan([path: ["a"]])

        XCTAssertEqual(plan.diff(relativeTo: root), [
            "--- a/App/Localizable.xcstrings",
            "+++ b/App/Localizable.xcstrings",
            "@@ -1,8 +1,5 @@",
            " {",
            "   \"strings\" : {",
            "-    \"a\" : {",
            "-",
            "-    },",
            "     \"b\" : {",
            " ",
            "     }",
        ].map { $0 + "\n" }.joined())
        XCTAssertEqual(plan.summary(relativeTo: root, applying: false), "Would remove 1 unused String Catalog key in 1 file, skipped 0 keys.")
        XCTAssertEqual(try contents(path), original)
    }

    func testApplyWritesTheFixedBytesAndKeepsThePermissions() throws {
        let path = try catalog()
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: path.string)
        let plan = planner().plan([path: ["a"]])

        try FixWriter.apply(plan)

        XCTAssertEqual(try contents(path), fixed)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: path.string)[.posixPermissions] as? Int, 0o640)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.string), ["Localizable.xcstrings"])
        XCTAssertEqual(planner().plan([path: ["a"]]).skipped.map(\.reason), [.catalogRefused(.keysNotFound(["a"]))])
    }

    func testApplyWritesNothingWhenAFileChangedSincePlanning() throws {
        let first = try catalog("A.xcstrings")
        let second = try catalog("B.xcstrings")
        let plan = planner().plan([first: ["a"], second: ["b"]])
        XCTAssertEqual(plan.changes.count, 2)
        try Data("{}".utf8).write(to: URL(fileURLWithPath: second.string))

        XCTAssertThrowsError(try FixWriter.apply(plan))
        XCTAssertEqual(try contents(first), original)
        XCTAssertEqual(try contents(second), "{}")
    }

    func testApplyRestoresTheWrittenFilesWhenALaterWriteFails() throws {
        let first = try catalog("A.xcstrings")
        let second = try catalog("B.xcstrings")
        let plan = planner().plan([first: ["a"], second: ["b"]])

        XCTAssertThrowsError(try FixWriter.apply(plan) { permissions, path in
            guard !path.contains("B.xcstrings") else { throw CocoaError(.fileWriteNoPermission) }

            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: path)
        })
        XCTAssertEqual(try contents(first), original)
        XCTAssertEqual(try contents(second), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.string).sorted(), ["A.xcstrings", "B.xcstrings"])
    }

    func testRefusalsAreReportedPerFileAndNothingIsPlannedForThem() throws {
        let missingKey = try catalog("MissingKey.xcstrings")
        let link = root.appending("Link.xcstrings")
        try FileManager.default.createSymbolicLink(atPath: link.string, withDestinationPath: missingKey.string)
        let outside = try makeTemporaryDirectory("FixPlanTestOutside")
        defer { try? FileManager.default.removeItem(at: outside) }
        let outsidePath = FilePath(outside.resolvingSymlinksInPath().appendingPathComponent("O.xcstrings").path)
        try Data(original.utf8).write(to: URL(fileURLWithPath: outsidePath.string))

        let plan = planner().plan([missingKey: ["zz"], link: ["a"], outsidePath: ["a"], root.appending("None.xcstrings"): ["a"]])

        XCTAssertEqual(plan.changes.count, 0)
        XCTAssertEqual(reasons(plan), [
            "MissingKey.xcstrings": .catalogRefused(.keysNotFound(["zz"])),
            "Link.xcstrings": .symbolicLink,
            outsidePath.relativeTo(root).string: .outsideProject,
            "None.xcstrings": .unreadableFile,
        ])
        XCTAssertTrue(plan.summary(relativeTo: root, applying: true).hasPrefix("Removed 0 unused String Catalog keys in 0 files, skipped 4 keys.\n"))
    }

    func testCatalogModifiedAfterTheScanStartedIsRefused() throws {
        let path = try catalog()

        XCTAssertEqual(planner(scanStartedAt: Date(timeIntervalSinceNow: -3600)).plan([path: ["a"]]).skipped.map(\.reason), [.changedSinceScan])
        XCTAssertEqual(planner(scanStartedAt: Date(timeIntervalSinceNow: 60)).plan([path: ["a"]]).changes.count, 1)
    }

    func testDirtyUntrackedAndIgnoredFilesAreRefusedInAGitRepository() throws {
        let clean = try catalog("Clean.xcstrings")
        let dirty = try catalog("Dirty.xcstrings")
        try Data("Ignored.xcstrings\n".utf8).write(to: URL(fileURLWithPath: root.appending(".gitignore").string))
        try git("init", "-q")
        try git("add", ".")
        try git("commit", "-q", "-m", "init")
        try Data((original + "\n").utf8).write(to: URL(fileURLWithPath: dirty.string))
        let untracked = try catalog("Untracked.xcstrings")
        let ignored = try catalog("Ignored.xcstrings")

        let plan = try planner(GitWorkingTree.state(at: root)).plan([clean: ["a"], dirty: ["a"], untracked: ["a"], ignored: ["a"]])

        XCTAssertEqual(plan.changes.map(\.path), [clean])
        XCTAssertEqual(reasons(plan), [
            "Dirty.xcstrings": .uncommittedChanges,
            "Untracked.xcstrings": .uncommittedChanges,
            "Ignored.xcstrings": .notTrackedByGit,
        ])
        XCTAssertEqual(planner(.ignored).plan([dirty: ["a"]]).changes.count, 1)
    }

    func testOutsideAGitRepositoryIsRefusedUnlessAllowed() throws {
        let path = try catalog()
        guard case .notARepository = try GitWorkingTree.state(at: root) else {
            return XCTFail("a temporary directory is outside any repository")
        }

        XCTAssertEqual(planner(.notARepository).plan([path: ["a"]]).skipped.map(\.reason), [.notInGitRepository])
        XCTAssertEqual(planner(.ignored).plan([path: ["a"]]).changes.count, 1)
    }

    func testGitFailureIsNotReportedAsNotARepository() throws {
        _ = try catalog()
        try git("init", "-q")
        try git("add", ".")
        try git("commit", "-q", "-m", "init")
        try Data("corrupt".utf8).write(to: URL(fileURLWithPath: root.appending(".git/index").string))

        XCTAssertThrowsError(try GitWorkingTree.state(at: root)) { error in
            XCTAssertTrue("\(error)".contains("git status"), "\(error)")
        }
    }
}
