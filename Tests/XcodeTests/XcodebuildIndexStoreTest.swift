import Foundation
import Logger
import Shared
import SystemPackage
import TestShared
@testable import XcodeSupport
import XCTest

final class XcodebuildIndexStoreTest: XCTestCase {
    private var root: FilePath!
    private var xcodebuild: Xcodebuild!
    private var project: XcodeProject!

    override func setUpWithError() throws {
        let shell = ShellMock(output: "Xcode 0.0")
        let logger = Logger(quiet: true, verbose: false, colorMode: .never)
        let tmp = FilePath(NSTemporaryDirectory()).appending("periphery-index-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: tmp.string, withIntermediateDirectories: true)
        root = tmp
        xcodebuild = Xcodebuild(shell: shell, logger: logger, cacheDirectory: TestCacheDirectory.path)
        var loaded: Set<FilePath> = []
        project = try XcodeProject(path: UIKitProjectPath, loadedProjectPaths: &loaded, xcodebuild: xcodebuild, shell: shell, logger: logger)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: root.string)
    }

    private var projectName: String {
        project.path.lexicallyNormalized().lastComponent?.stem ?? ""
    }

    @discardableResult
    private func makeDataStore(in folder: String, modified: Date, workspacePath: String? = nil) throws -> FilePath {
        let store = root.appending(folder).appending("Index.noindex/DataStore")
        try FileManager.default.createDirectory(atPath: store.string, withIntermediateDirectories: true)
        let info = ["WorkspacePath": workspacePath ?? project.path.lexicallyNormalized().string]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: URL(fileURLWithPath: root.appending(folder).appending("info.plist").string))
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: store.string)
        return store
    }

    func testSkippedBuildFallsBackToMostRecentXcodeDerivedData() throws {
        try makeDataStore(in: "\(projectName)-old", modified: Date(timeIntervalSince1970: 1000))
        let newest = try makeDataStore(in: "\(projectName)-new", modified: Date(timeIntervalSince1970: 2000))
        try makeDataStore(in: "\(projectName)Other-zzz", modified: Date(timeIntervalSince1970: 3000))

        let path = try xcodebuild.indexStorePath(project: project, schemes: [], skipBuild: true, xcodeDerivedDataRoot: root)

        XCTAssertEqual(path, newest)
    }

    func testSkipBuildFallback_ignoresDerivedDataOfAnotherWorkspace() throws {
        let own = try makeDataStore(in: "\(projectName)-own", modified: Date(timeIntervalSince1970: 1000))
        try makeDataStore(
            in: "\(projectName)-clone",
            modified: Date(timeIntervalSince1970: 2000),
            workspacePath: "/elsewhere/\(projectName).xcodeproj"
        )

        let path = try xcodebuild.indexStorePath(project: project, schemes: [], skipBuild: true, xcodeDerivedDataRoot: root)

        XCTAssertEqual(path, own)
    }

    func testSkippedBuildWithoutAnyIndexStoreListsTriedPaths() throws {
        XCTAssertThrowsError(
            try xcodebuild.indexStorePath(project: project, schemes: [], skipBuild: true, xcodeDerivedDataRoot: root)
        ) { error in
            guard case let PeripheryError.indexStoreNotFoundAfterSkippedBuild(tried) = error else {
                return XCTFail("Unexpected error: \(error)")
            }

            XCTAssertTrue(tried.contains { $0.contains("DerivedData-") })
            XCTAssertTrue(tried.contains { $0.hasPrefix(root.string) && $0.contains("\(projectName)-*") })
        }
    }

    func testBuildNotSkippedDoesNotFallBackToXcodeDerivedData() throws {
        try makeDataStore(in: "\(projectName)-abc", modified: Date())

        XCTAssertThrowsError(
            try xcodebuild.indexStorePath(project: project, schemes: [], skipBuild: false, xcodeDerivedDataRoot: root)
        ) { error in
            guard case PeripheryError.indexStoreNotFound = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testSkipBuildFallback_reportsAnUnreadableDerivedDataRoot() throws {
        let unreadableRoot = root.appending("not-a-directory")
        try Data().write(to: URL(fileURLWithPath: unreadableRoot.string))
        let logger = Logger(quiet: false, verbose: false, colorMode: .never)
        let xcodebuild = Xcodebuild(shell: ShellMock(output: "Xcode 0.0"), logger: logger, cacheDirectory: TestCacheDirectory.path)
        var thrown: Error?

        let stderr = try captureStandardError {
            XCTAssertThrowsError(
                try xcodebuild.indexStorePath(project: project, schemes: [], skipBuild: true, xcodeDerivedDataRoot: unreadableRoot)
            ) { thrown = $0 }
        }

        guard case PeripheryError.indexStoreNotFoundAfterSkippedBuild = try XCTUnwrap(thrown) else {
            return XCTFail("Unexpected error: \(String(describing: thrown))")
        }

        XCTAssertTrue(stderr.contains("Cannot read Xcode's DerivedData folder \(unreadableRoot.string)"), stderr)
    }

    func testSkipBuildFallback_missingDerivedDataRootIsNotReported() throws {
        let logger = Logger(quiet: false, verbose: false, colorMode: .never)
        let xcodebuild = Xcodebuild(shell: ShellMock(output: "Xcode 0.0"), logger: logger, cacheDirectory: TestCacheDirectory.path)

        let stderr = try captureStandardError {
            XCTAssertThrowsError(
                try xcodebuild.indexStorePath(project: project, schemes: [], skipBuild: true, xcodeDerivedDataRoot: root.appending("missing"))
            )
        }

        XCTAssertFalse(stderr.contains("Cannot read"), stderr)
    }

    private func captureStandardError(_ body: () throws -> Void) throws -> String {
        let pipe = Pipe()
        let original = dup(STDERR_FILENO)
        fflush(stderr)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)

        defer {
            dup2(original, STDERR_FILENO)
            close(original)
        }

        try body()
        fflush(stderr)
        dup2(original, STDERR_FILENO)
        pipe.fileHandleForWriting.closeFile()
        return try XCTUnwrap(String(bytes: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8))
    }
}
