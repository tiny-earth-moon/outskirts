import Foundation
@testable import Shared
import SystemPackage
import XCTest

/// The files outskirts writes besides the fixes: the ones the user names, and the ones it chooses itself.
final class OutputFileTest: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("OutputFileTest-\(UUID().uuidString)")
        try fm.createDirectory(at: root.appendingPathComponent("project"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("outside"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try fm.removeItem(at: root)
    }

    private func path(_ relative: String) -> FilePath {
        FilePath(root.appendingPathComponent(relative).path)
    }

    func testNamedOutput_replacesARegularFileAtomically() throws {
        try Data("old".utf8).write(to: root.appendingPathComponent("project/results.txt"))

        try OutputFile.write(Data("new".utf8), to: path("project/results.txt"))

        XCTAssertEqual(try String(contentsOfFile: path("project/results.txt").string, encoding: .utf8), "new")
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: path("project").string), ["results.txt"])
    }

    func testNamedOutput_writesTheTargetOfASymbolicLinkAndKeepsTheLink() throws {
        try Data("old".utf8).write(to: root.appendingPathComponent("outside/results.txt"))
        try fm.createSymbolicLink(atPath: path("project/results.txt").string, withDestinationPath: path("outside/results.txt").string)

        let written = try OutputFile.write(Data("new".utf8), to: path("project/results.txt"))

        XCTAssertEqual(try String(contentsOfFile: path("outside/results.txt").string, encoding: .utf8), "new")
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: path("project/results.txt").string), path("outside/results.txt").string)
        XCTAssertEqual(written.lastComponent?.string, "results.txt")
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: path("outside").string), ["results.txt"])
    }

    func testNamedOutput_createsTheMissingTargetOfADanglingLink() throws {
        try fm.createSymbolicLink(atPath: path("project/results.txt").string, withDestinationPath: "../outside/new.txt")

        try OutputFile.write(Data("new".utf8), to: path("project/results.txt"))

        XCTAssertEqual(try String(contentsOfFile: path("outside/new.txt").string, encoding: .utf8), "new")
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: path("project/results.txt").string), "../outside/new.txt")
    }

    func testConfiguredOutput_refusesALinkLeadingOutsideTheProjectRoot() throws {
        try Data("kept".utf8).write(to: root.appendingPathComponent("outside/.zshrc"))
        try fm.createSymbolicLink(atPath: path("project/baseline.json").string, withDestinationPath: path("outside/.zshrc").string)

        XCTAssertThrowsError(try OutputFile.writeConfigured(Data("new".utf8), to: path("project/baseline.json"), projectRoot: path("project"))) { error in
            XCTAssertTrue("\(error)".contains("from the configuration file"), "\(error)")
        }

        XCTAssertEqual(try String(contentsOfFile: path("outside/.zshrc").string, encoding: .utf8), "kept")
    }

    func testConfiguredOutput_refusesALinkedDirectoryLeadingOutsideTheProjectRoot() throws {
        try fm.createSymbolicLink(atPath: path("project/out").string, withDestinationPath: path("outside").string)

        XCTAssertThrowsError(try OutputFile.writeConfigured(Data("new".utf8), to: path("project/out/results.txt"), projectRoot: path("project")))

        XCTAssertFalse(fm.fileExists(atPath: path("outside/results.txt").string))
    }

    func testConfiguredOutput_writesThroughALinkInsideTheProjectRootAndKeepsIt() throws {
        try fm.createDirectory(at: root.appendingPathComponent("project/shared"), withIntermediateDirectories: true)
        try Data("old".utf8).write(to: root.appendingPathComponent("project/shared/baseline.json"))
        try fm.createSymbolicLink(atPath: path("project/baseline.json").string, withDestinationPath: "shared/baseline.json")

        try OutputFile.writeConfigured(Data("new".utf8), to: path("project/baseline.json"), projectRoot: path("project"))

        XCTAssertEqual(try String(contentsOfFile: path("project/shared/baseline.json").string, encoding: .utf8), "new")
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: path("project/baseline.json").string), "shared/baseline.json")
    }

    func testConfiguredOutput_refusesADanglingLinkAndCreatesNothing() throws {
        try fm.createSymbolicLink(atPath: path("project/baseline.json").string, withDestinationPath: "shared/missing.json")

        XCTAssertThrowsError(try OutputFile.writeConfigured(Data("new".utf8), to: path("project/baseline.json"), projectRoot: path("project"))) { error in
            XCTAssertTrue("\(error)".contains("dangling"), "\(error)")
        }

        XCTAssertFalse(fm.fileExists(atPath: path("project/shared").string))
        XCTAssertTrue(OutputFile.isSymbolicLink(path("project/baseline.json").string))
    }

    func testConfiguredOutput_refusesAPlainPathOutsideTheProjectRoot() throws {
        try Data("kept".utf8).write(to: root.appendingPathComponent("outside/.zshrc"))

        for configured in [path("outside/.zshrc"), FilePath(path("project").string + "/../outside/.zshrc")] {
            XCTAssertThrowsError(try OutputFile.writeConfigured(Data("new".utf8), to: configured, projectRoot: path("project"))) { error in
                XCTAssertTrue("\(error)".contains("on the command line"), "\(error)")
            }
        }

        XCTAssertEqual(try String(contentsOfFile: path("outside/.zshrc").string, encoding: .utf8), "kept")
    }

    func testConfiguredOutput_writesAPlainPathInsideTheProjectRoot() throws {
        try OutputFile.writeConfigured(Data("new".utf8), to: path("project/results.txt"), projectRoot: path("project"))

        XCTAssertEqual(try String(contentsOfFile: path("project/results.txt").string, encoding: .utf8), "new")
    }

    func testConfinedWrite_refusesALinkLeadingOutsideTheRoot() throws {
        try Data("kept".utf8).write(to: root.appendingPathComponent("outside/config.yml"))
        try fm.createSymbolicLink(atPath: path("project/.outskirts.yml").string, withDestinationPath: path("outside/config.yml").string)

        XCTAssertThrowsError(try OutputFile.writeConfined(Data("new".utf8), to: path("project/.outskirts.yml"), within: path("project"))) { error in
            XCTAssertTrue("\(error)".contains("outside"), "\(error)")
        }

        XCTAssertEqual(try String(contentsOfFile: path("outside/config.yml").string, encoding: .utf8), "kept")
    }

    func testConfinedWrite_refusesADirectoryLinkLeadingOutsideTheRoot() throws {
        try fm.createSymbolicLink(atPath: path("project/linked").string, withDestinationPath: path("outside").string)

        XCTAssertThrowsError(try OutputFile.writeConfined(Data("new".utf8), to: path("project/linked/new.txt"), within: path("project")))

        XCTAssertFalse(fm.fileExists(atPath: path("outside/new.txt").string))
    }

    func testConfinedWrite_writesTheTargetOfALinkInsideTheRootAndKeepsTheLink() throws {
        try fm.createDirectory(at: root.appendingPathComponent("project/config"), withIntermediateDirectories: true)
        try Data("old".utf8).write(to: root.appendingPathComponent("project/config/outskirts.yml"))
        try fm.createSymbolicLink(atPath: path("project/.outskirts.yml").string, withDestinationPath: "config/outskirts.yml")

        try OutputFile.writeConfined(Data("new".utf8), to: path("project/.outskirts.yml"), within: path("project"))

        XCTAssertEqual(try String(contentsOfFile: path("project/config/outskirts.yml").string, encoding: .utf8), "new")
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: path("project/.outskirts.yml").string), "config/outskirts.yml")
    }

    func testConfinedWrite_createsAMissingFileInsideTheRoot() throws {
        try OutputFile.writeConfined(Data("new".utf8), to: path("project/new.txt"), within: path("project"))

        XCTAssertEqual(try String(contentsOfFile: path("project/new.txt").string, encoding: .utf8), "new")
    }
}
