import Configuration
import Foundation
@testable import Indexer
import Logger
import Shared
import SystemPackage
import TestShared
import XCTest

/// `--index-built-from` against a real git repository created in a temporary directory, with injected unit dates.
final class GitIndexFreshnessTest: XCTestCase {
    private var root: FilePath!

    private let built = Date(timeIntervalSince1970: 1_000_000)

    override func setUpWithError() throws {
        root = try FilePath(makeTemporaryDirectory("outskirts-index-built-from").path)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(atPath: root.string)
    }

    // MARK: - Fixtures

    @discardableResult
    private func git(_ arguments: String...) throws -> String {
        try Git.run(arguments, in: root)
    }

    private func write(_ content: String, to name: String) throws {
        let path = root.appending(name)
        try FileManager.default.createDirectory(atPath: path.removingLastComponent().string, withIntermediateDirectories: true)
        try Data(content.utf8).write(to: URL(fileURLWithPath: path.string))
    }

    private func commit(_ message: String) throws {
        try git("add", "-A")
        try git("commit", "-q", "-m", message)
    }

    /// One commit with `Sources/A.swift` and `Sources/B.swift`.
    private func makeRepository() throws {
        try git("init", "-q")
        try git("config", "user.name", "Test")
        try git("config", "user.email", "test@example.com")
        try git("config", "commit.gpgsign", "false")
        try write("struct A {}\n", to: "Sources/A.swift")
        try write("struct B {}\n", to: "Sources/B.swift")
        try commit("first")
    }

    private func freshness(_ revision: String = "HEAD") throws -> GitIndexFreshness {
        try GitIndexFreshness.read(revision: revision, in: root)
    }

    private func file(_ name: String) -> FilePath {
        root.appending(name)
    }

    private func modificationDate(of name: String) throws -> Date {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file(name).string)[.modificationDate] as? Date)
    }

    private func outdated(_ name: String, changedSinceRevision: Bool?) throws -> [Date] {
        SourceFileCollector.outdatedUnits(
            [built],
            sourceModificationDate: try modificationDate(of: name),
            changedSinceRevision: changedSinceRevision,
            modificationDate: { $0 }
        )
    }

    // MARK: - Source files described by units

    /// A copy or a checkout made after the build: every file is newer than its units, but none changed.
    func testUnchangedFileNewerThanItsUnits_isNotOutdatedWithARevision() throws {
        try makeRepository()

        let changed = try freshness().hasChanged(file("Sources/A.swift"))

        XCTAssertEqual(changed, false)
        XCTAssertEqual(try outdated("Sources/A.swift", changedSinceRevision: changed), [])
        XCTAssertEqual(try outdated("Sources/A.swift", changedSinceRevision: nil), [built], "without the option, the date decides")
    }

    func testModifiedFile_isOutdated() throws {
        try makeRepository()
        try write("struct A { let b: B }\n", to: "Sources/A.swift")

        let freshness = try freshness()

        XCTAssertEqual(freshness.hasChanged(file("Sources/A.swift")), true)
        XCTAssertEqual(freshness.hasChanged(file("Sources/B.swift")), false)
        XCTAssertEqual(try outdated("Sources/A.swift", changedSinceRevision: true), [built])
    }

    /// A modified file whose date was set back before the build is outdated by content, not by date.
    func testModifiedFileSetToAnOldDate_isOutdatedOnlyWithARevision() throws {
        try makeRepository()
        try write("struct A { let b: B }\n", to: "Sources/A.swift")
        try FileManager.default.setAttributes([.modificationDate: built.addingTimeInterval(-3600)], ofItemAtPath: file("Sources/A.swift").string)

        let changed = try freshness().hasChanged(file("Sources/A.swift"))

        XCTAssertEqual(changed, true)
        XCTAssertEqual(try outdated("Sources/A.swift", changedSinceRevision: changed), [built])
        XCTAssertEqual(try outdated("Sources/A.swift", changedSinceRevision: nil), [])
    }

    func testFileCommittedAfterTheRevision_isOutdated() throws {
        try makeRepository()
        try write("struct A { let b: B }\n", to: "Sources/A.swift")
        try commit("second")

        XCTAssertEqual(try freshness("HEAD~1").hasChanged(file("Sources/A.swift")), true)
        XCTAssertEqual(try freshness("HEAD").hasChanged(file("Sources/A.swift")), false)
    }

    /// The unit of a deleted source file describes declarations that no longer exist.
    func testDeletedFile_isOutdated() throws {
        try makeRepository()
        try FileManager.default.removeItem(atPath: file("Sources/A.swift").string)

        XCTAssertEqual(try freshness().hasChanged(file("Sources/A.swift")), true)
    }

    /// A renamed file is its deleted old path, whose unit is outdated, and its new path, which no unit describes.
    func testRenamedFile_isOutdatedAndNotInTheIndex() throws {
        try makeRepository()
        try git("mv", "Sources/A.swift", "Sources/Renamed.swift")
        try commit("rename")

        let freshness = try freshness("HEAD~1")

        XCTAssertEqual(freshness.hasChanged(file("Sources/A.swift")), true)
        XCTAssertEqual(unindexed(freshness, indexed: ["Sources/A.swift", "Sources/B.swift"]), ["Sources/Renamed.swift"])
    }

    // MARK: - Files no unit describes

    private func unindexed(_ freshness: GitIndexFreshness, indexed: [String]) -> [String] {
        freshness.unindexedChanges(indexed: Set(indexed.map(file)), in: root) { _ in false }
            .map { String($0.string.dropFirst(RealPath.resolve(root.string).count + 1)) }
            .sorted()
    }

    /// A source file added since the build has no index data: the declarations it uses may be reported as unused.
    func testAddedFiles_committedOrUntracked_areNotInTheIndex() throws {
        try makeRepository()
        try write("struct C {}\n", to: "Sources/C.swift")
        try commit("second")
        try write("struct D {}\n", to: "Sources/D.swift")

        let freshness = try freshness("HEAD~1")

        XCTAssertEqual(freshness.hasChanged(file("Sources/D.swift")), true)
        XCTAssertEqual(unindexed(freshness, indexed: ["Sources/A.swift", "Sources/B.swift"]), ["Sources/C.swift", "Sources/D.swift"])
        XCTAssertEqual(unindexed(freshness, indexed: ["Sources/A.swift", "Sources/C.swift", "Sources/D.swift"]), [])
    }

    /// A Swift file modified (not added) without unit is not compiled, so it cannot make the index outdated.
    func testModifiedSwiftFileWithoutUnit_isIgnored() throws {
        try makeRepository()
        try write("struct B2 {}\n", to: "Sources/B.swift")

        XCTAssertEqual(unindexed(try freshness(), indexed: ["Sources/A.swift"]), [])
    }

    func testChangedFilesReadByTheScan_areReported() throws {
        try makeRepository()
        let read = [
            "App/Localizable.xcstrings", "App/Info.plist", "App/Main.storyboard", "App/View.xib", "App/Shaders.metal",
            "App.xcodeproj/project.pbxproj", "App.xcworkspace/contents.xcworkspacedata", "Package.swift", "Package@swift-6.0.swift",
            "App/Model.xcdatamodeld/Model.xcdatamodel/contents", "App/Mapping.xcmappingmodel/xcmapping.xml",
            "App/Assets.xcassets/Icon.imageset/Contents.json",
        ]
        let notRead = ["App/Localizable.strings", "project.yml", "README.md", "Package.resolved"]
        for name in read + notRead {
            try write("x\n", to: name)
        }

        XCTAssertEqual(unindexed(try freshness(), indexed: []), read.sorted())
    }

    func testChangedFilesOutsideTheProjectRootOrExcluded_areIgnored() throws {
        try makeRepository()
        try write("struct C {}\n", to: "Other/C.swift")
        try write("struct D {}\n", to: "Sources/D.swift")
        let real = FilePath(RealPath.resolve(root.string))

        let unindexed = try freshness().unindexedChanges(indexed: [], in: root.appending("Sources")) { $0 == real.appending("Sources/D.swift") }

        XCTAssertEqual(unindexed, [])
    }

    // MARK: - Files git does not judge

    func testFilesOutsideTheRepositoryOrIgnored_areJudgedByDate() throws {
        try makeRepository()
        try write("Generated/\n", to: ".gitignore")
        try write("struct G {}\n", to: "Generated/G.swift")
        let outside = try FilePath(makeTemporaryDirectory("outskirts-outside").path).appending("O.swift")
        addTeardownBlock { try? FileManager.default.removeItem(atPath: outside.removingLastComponent().string) }
        try Data("struct O {}\n".utf8).write(to: URL(fileURLWithPath: outside.string))

        let freshness = try freshness()

        XCTAssertNil(freshness.hasChanged(file("Generated/G.swift")))
        XCTAssertNil(freshness.hasChanged(outside))
    }

    // MARK: - Errors

    func testUnknownRevision_throws() throws {
        try makeRepository()

        for revision in ["no-such-revision", "--all"] {
            XCTAssertThrowsError(try freshness(revision)) { error in
                guard case let .indexBuiltFromUnknownRevision(given, _, _)? = error as? PeripheryError else {
                    return XCTFail("Unexpected error: \(error)")
                }

                XCTAssertEqual(given, revision)
            }
        }
    }

    func testOutsideAGitRepository_throws() throws {
        XCTAssertThrowsError(try freshness()) { error in
            guard case .indexBuiltFromNotInGitWorkTree? = error as? PeripheryError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    /// The scan never falls back to the dates when the revision cannot be read.
    func testCollect_outsideAGitRepository_throwsBeforeReadingTheIndex() throws {
        let configuration = Configuration()
        configuration.projectRoot = root
        configuration.indexBuiltFrom = "HEAD"
        let collector = SourceFileCollector(
            indexStorePaths: [root.appending("missing-store")],
            excludedTestTargets: [],
            logger: Logger(quiet: true, verbose: false, colorMode: .never).contextualized(with: "test"),
            configuration: configuration
        )

        XCTAssertThrowsError(try collector.collect()) { error in
            guard case .indexBuiltFromNotInGitWorkTree? = error as? PeripheryError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    // MARK: - Duplicate units and warning

    /// Git cannot tell which unit was written from the revision, so the newest unit of a module still wins.
    func testDuplicateUnitsOfAModule_newestStillWinsWithARevision() {
        let units = [built.addingTimeInterval(-600), built.addingTimeInterval(60)]
        let kept = SourceFileCollector.currentUnits(units, sourceModificationDate: built, module: { _ in "Kit" }, modificationDate: { $0 })

        XCTAssertEqual(kept, [built.addingTimeInterval(60)])
        XCTAssertEqual(SourceFileCollector.outdatedUnits(kept, sourceModificationDate: built, changedSinceRevision: false, modificationDate: { $0 }), [])
    }

    func testChangedSinceRevisionWarning_namesTheRevisionStoresAndUnindexedFiles() throws {
        let changed: [FilePath: Set<FilePath>] = ["/project/.build/store": ["/project/Sources/A.swift", "/project/Sources/B.swift"]]

        XCTAssertNil(SourceFileCollector.changedSinceRevisionWarning([:], unindexed: [], revision: "abc123", relativeTo: "/project"))
        XCTAssertEqual(
            SourceFileCollector.changedSinceRevisionWarning(changed, unindexed: [], revision: "abc123", relativeTo: "/project"),
            "2 files changed since abc123, the revision the index was built from, in .build/store: Sources/A.swift, Sources/B.swift. Results may be at the wrong lines or missing: rebuild the project before scanning, or pass '--clean-build' to start from an empty index store."
        )
        XCTAssertEqual(
            SourceFileCollector.changedSinceRevisionWarning(changed, unindexed: ["/project/Sources/C.swift"], revision: "abc123", relativeTo: "/project"),
            "3 files changed since abc123, the revision the index was built from: 2 in .build/store (Sources/A.swift, Sources/B.swift), 1 not in the index (Sources/C.swift). Results may be at the wrong lines or missing: rebuild the project before scanning, or pass '--clean-build' to start from an empty index store."
        )
        XCTAssertThrowsError(try SourceFileCollector.changedSinceRevisionWarning(changed, unindexed: [], revision: "abc123", relativeTo: "/project", strict: true)) { error in
            guard case let .outdatedIndexData(message)? = error as? PeripheryError else {
                return XCTFail("Unexpected error: \(error)")
            }

            XCTAssertTrue(message.hasSuffix("Failing as '--strict-index' is set."), message)
        }
    }
}
