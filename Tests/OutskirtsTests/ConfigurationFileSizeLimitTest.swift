import Configuration
import Foundation
import Shared
import SystemPackage
import TestShared
import XCTest

final class ConfigurationFileSizeLimitTest: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = try makeTemporaryDirectory("periphery-config-size")
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    func testOversizedConfigurationIsRejectedBeforeParsing() throws {
        let size = 1024 * 1024 + 1
        let file = try write(String(repeating: "#", count: size))

        XCTAssertThrowsError(try Configuration().load(from: file) { _ in }) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "\(file.string): the configuration file is \(size) bytes, larger than the 1048576 bytes limit"
            )
        }
    }

    func testConfigurationAtTheLimitIsLoaded() throws {
        let header = "retain_public: true\n"
        let file = try write(header + String(repeating: "#", count: 1024 * 1024 - header.utf8.count))
        let configuration = Configuration()

        try configuration.load(from: file) { _ in }

        XCTAssertTrue(configuration.retainPublic)
    }

    func testConfigurationThatIsNotUTF8IsRejected() throws {
        let url = directory.appendingPathComponent(".periphery.yml")
        try Data([0xFF, 0xFE, 0x00]).write(to: url)
        let file = FilePath(url.path)

        XCTAssertThrowsError(try Configuration().load(from: file) { _ in }) { error in
            XCTAssertEqual(error.localizedDescription, "\(file.string): the configuration file is not valid UTF-8")
        }
    }

    private func write(_ contents: String) throws -> FilePath {
        try writeFile(contents, named: ".periphery.yml", in: directory)
    }
}
