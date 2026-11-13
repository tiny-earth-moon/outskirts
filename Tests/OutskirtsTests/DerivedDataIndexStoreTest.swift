import Foundation
import Shared
import SystemPackage
import TestShared
import XCTest

final class DerivedDataIndexStoreTest: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try makeTemporaryDirectory("outskirts-derived-data")
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private func makeDirectory(_ relativePath: String) throws -> FilePath {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return FilePath(url.path)
    }

    func testResolvesTheDataStoreOfADerivedDataDirectory() throws {
        let store = try makeDirectory("DD/Index.noindex/DataStore")

        XCTAssertEqual(try DerivedDataIndexStore.resolve(derivedDataPath: FilePath(root.path).appending("DD")), store)
    }

    func testResolvesTheLegacyDataStoreLocation() throws {
        let store = try makeDirectory("DD/Index/DataStore")

        XCTAssertEqual(try DerivedDataIndexStore.resolve(derivedDataPath: FilePath(root.path).appending("DD")), store)
    }

    func testMissingDirectoryThrowsANamedError() {
        let missing = FilePath(root.path).appending("Missing")

        XCTAssertThrowsError(try DerivedDataIndexStore.resolve(derivedDataPath: missing)) { error in
            guard case let PeripheryError.derivedDataPathNotFound(path) = error else { return XCTFail("\(error)") }

            XCTAssertEqual(path, missing.string)
        }
    }

    func testDirectoryWithoutIndexStoreThrowsANamedError() throws {
        let derivedData = try makeDirectory("DD/Build")
            .removingLastComponent()

        XCTAssertThrowsError(try DerivedDataIndexStore.resolve(derivedDataPath: derivedData)) { error in
            guard case let PeripheryError.derivedDataIndexStoreNotFound(path, tried) = error else { return XCTFail("\(error)") }

            XCTAssertEqual(path, derivedData.string)
            XCTAssertEqual(tried.first, derivedData.appending("Index.noindex/DataStore").string)
            XCTAssertTrue(error.localizedDescription.contains(derivedData.string))
        }
    }

    func testMergeAddsStoresToIndexStorePathsWithoutDuplicates() throws {
        let iosStore = try makeDirectory("iOS/Index.noindex/DataStore")
        let macStore = try makeDirectory("macOS/Index.noindex/DataStore")
        let base = FilePath(root.path)

        let merged = try DerivedDataIndexStore.merge(
            indexStorePaths: [iosStore],
            derivedDataPaths: [base.appending("iOS"), base.appending("macOS"), base.appending("macOS/./")]
        )

        XCTAssertEqual(merged, [iosStore, macStore])
    }

    func testMergeWithoutDerivedDataKeepsIndexStorePaths() throws {
        let paths = [FilePath("a"), FilePath("b")]

        XCTAssertEqual(try DerivedDataIndexStore.merge(indexStorePaths: paths, derivedDataPaths: []), paths)
    }
}
