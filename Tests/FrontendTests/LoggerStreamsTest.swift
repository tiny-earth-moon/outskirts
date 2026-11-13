import Extensions
import Foundation
@testable import Logger
import Shared
import SystemPackage
import TestShared
import XCTest

final class LoggerStreamsTest: XCTestCase {
    func testAutoColorRequiresATerminalAndHonorsNoColor() {
        let term = ["TERM": "xterm-256color"]

        XCTAssertTrue(Logger.isColorCapable(environment: term, isTerminal: true))
        XCTAssertFalse(Logger.isColorCapable(environment: term, isTerminal: false))
        XCTAssertFalse(Logger.isColorCapable(environment: ["TERM": "dumb"], isTerminal: true))
        XCTAssertFalse(Logger.isColorCapable(environment: term.merging(["NO_COLOR": "1"]) { $1 }, isTerminal: true))
        XCTAssertTrue(Logger.isColorCapable(environment: term.merging(["NO_COLOR": ""]) { $1 }, isTerminal: true))
    }

    func testAutoDoesNotColorWarningsWhenStderrIsNotATerminal() {
        let logger = Logger(quiet: false, verbose: false, colorMode: .auto)

        let (_, stderr) = capture {
            logger.warn("warn")
            logger.error("error")
        }

        XCTAssertEqual(stderr, "warning: warn\nerror: error\n")
    }

    func testMessagesGoToStdoutByDefault() {
        let logger = Logger(quiet: false, verbose: true, colorMode: .never)

        let (stdout, stderr) = capture {
            logger.info("info")
            logger.debug("debug")
        }

        XCTAssertEqual(stdout, "info\ndebug\n")
        XCTAssertEqual(stderr, "")
    }

    func testInfoAndDebugGoToStderrWhenMessagesAreRedirected() {
        let logger = Logger(quiet: false, verbose: true, colorMode: .never, messagesToStderr: true)

        let (stdout, stderr) = capture {
            logger.info("info")
            logger.debug("debug")
            logger.warn("warn")
        }

        XCTAssertEqual(stdout, "")
        XCTAssertEqual(stderr, "info\ndebug\nwarning: warn\n")
    }

    func testOutputAlwaysGoesToStdoutEvenWhenQuietOrRedirected() {
        let logger = Logger(quiet: true, verbose: false, colorMode: .never, messagesToStderr: true)

        let (stdout, stderr) = capture {
            logger.output("result")
            logger.info("progress")
        }

        XCTAssertEqual(stdout, "result\n")
        XCTAssertEqual(stderr, "")
    }

    func testUnreadableGlobDirectory_warnsThroughLoggerAndIsSilentWhenQuiet() throws {
        try XCTSkipIf(geteuid() == 0, "Directory permissions do not apply to root")
        let root = NSTemporaryDirectory() + "LoggerStreamsTest-\(UUID().uuidString)"
        let locked = root + "/locked"
        try FileManager.default.createDirectory(atPath: locked + "/sub", withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked)
            try? FileManager.default.removeItem(atPath: root)
        }
        let pattern = locked + "/**/*.swift"

        let logger = Logger(quiet: false, verbose: false, colorMode: .never)
        let (stdout, stderr) = capture {
            _ = FilePath.glob(pattern, onUnreadableDirectory: logger.warnUnreadableDirectory)
        }
        XCTAssertEqual(stdout, "")
        XCTAssertTrue(stderr.hasPrefix("warning: Cannot list directory '\(locked)'"), stderr)

        let quietLogger = Logger(quiet: true, verbose: false, colorMode: .never)
        let quiet = capture {
            _ = FilePath.glob(pattern, onUnreadableDirectory: quietLogger.warnUnreadableDirectory)
        }
        XCTAssertEqual(quiet.stdout, "")
        XCTAssertEqual(quiet.stderr, "")
    }

    // MARK: - Private

    private func capture(_ body: () -> Void) -> (stdout: String, stderr: String) {
        var stdoutText = ""
        let stderrText = redirect(STDERR_FILENO, of: stderr) {
            stdoutText = redirect(STDOUT_FILENO, of: stdout, body)
        }
        return (stdoutText, stderrText)
    }

    private func redirect(_ descriptor: Int32, of stream: UnsafeMutablePointer<FILE>, _ body: () -> Void) -> String {
        let file = uniqueTemporaryURL("periphery-logger")
        defer { try? FileManager.default.removeItem(at: file) }

        fflush(stream)
        let saved = dup(descriptor)
        let target = open(file.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        dup2(target, descriptor)
        close(target)

        body()

        fflush(stream)
        dup2(saved, descriptor)
        close(saved)
        return (try? String(contentsOf: file, encoding: .utf8)) ?? ""
    }
}
