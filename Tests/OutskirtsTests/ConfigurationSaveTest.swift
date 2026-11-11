import Configuration
import Foundation
import SystemPackage
import TestShared
import XCTest

final class ConfigurationSaveTest: XCTestCase {
    func testSaveIntoMissingDirectoryThrows() {
        let directory = uniqueTemporaryURL()
        let path = FilePath(directory.appendingPathComponent(".periphery.yml").path)

        XCTAssertThrowsError(try Configuration().save(to: path))
    }

    func testSaveWritesTheFile() throws {
        let directory = try makeTemporaryDirectory()
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let path = FilePath(directory.appendingPathComponent(".periphery.yml").path)

        try Configuration().save(to: path)

        XCTAssertTrue(FileManager.default.fileExists(atPath: path.string))
    }
}
