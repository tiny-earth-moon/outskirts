import Configuration
import Foundation
@testable import Frontend
import Logger
import Shared
import SystemPackage
import XCTest

final class GuidedSetupSaveTest: XCTestCase {
    private var path: FilePath!

    override func setUpWithError() throws {
        try super.setUpWithError()
        path = FilePath(FileManager.default.temporaryDirectory.appendingPathComponent("outskirts-\(UUID().uuidString).yml").path)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: path.string)
        try super.tearDownWithError()
    }

    func testConfirmSave_existingFileRequiresExplicitOverwrite() throws {
        try Data("retain_public: true\n".utf8).write(to: URL(fileURLWithPath: path.string))

        XCTAssertFalse(try confirm(answers: ["y", ""]), "empty answer refuses the overwrite")
        XCTAssertFalse(try confirm(answers: ["y", "n"]))
        XCTAssertTrue(try confirm(answers: ["y", "y"]))
        XCTAssertThrowsError(try confirm(answers: ["y"]), "end of input refuses the overwrite")
    }

    func testConfirmSave_newFileDoesNotAskToOverwrite() throws {
        XCTAssertTrue(try confirm(answers: ["y"]))
        XCTAssertFalse(try confirm(answers: ["n"]))
    }

    // MARK: - Private

    private func confirm(answers: [String]) throws -> Bool {
        let guidedSetup = GuidedSetup(
            configuration: Configuration(),
            shell: NoShell(),
            logger: Logger(quiet: true, verbose: false, colorMode: .never)
        )
        var remaining = answers
        guidedSetup.readInput = { remaining.isEmpty ? nil : remaining.removeFirst() }
        return try guidedSetup.confirmSave(to: path)
    }
}

private struct NoShell: Shell {
    func exec(_ args: [String]) throws -> String {
        throw PeripheryError.shellCommandFailed(cmd: args, status: 1, output: "unexpected command")
    }
}
