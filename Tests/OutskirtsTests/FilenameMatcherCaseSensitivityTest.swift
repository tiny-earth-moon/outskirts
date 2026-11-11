import Configuration
import Foundation
import SystemPackage
import TestShared
import XCTest

final class FilenameMatcherCaseSensitivityTest: XCTestCase {
    func testVolumeCaseSensitivityMatchesFilesystem() throws {
        let directory = try makeTemporaryDirectory()
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }

        try Data().write(to: directory.appendingPathComponent("probe.txt"))
        let upperExists = FileManager.default.fileExists(atPath: directory.appendingPathComponent("PROBE.TXT").path)

        XCTAssertEqual(try Configuration.volumeIsCaseSensitive(at: directory.path), !upperExists)
    }

    func testUnreadableVolumeThrows() throws {
        #if !canImport(Darwin)
            throw XCTSkip("Only Darwin reads the case sensitivity of a volume; Linux is always case-sensitive.")
        #endif
        let missing = uniqueTemporaryURL().path
        XCTAssertThrowsError(try Configuration.volumeIsCaseSensitive(at: missing))
    }

    func testMatchersFollowCurrentVolumeCaseSensitivity() throws {
        let pwd = FilePath.current.string
        let caseSensitive = try Configuration.volumeIsCaseSensitive(at: pwd)
        let matcher = Configuration().buildFilenameMatchers(with: ["Sources/File.swift"])[0]

        XCTAssertTrue(matcher.match(filename: "\(pwd)/Sources/File.swift"))
        XCTAssertEqual(matcher.match(filename: "\(pwd)/sources/file.swift"), !caseSensitive)
    }
}
