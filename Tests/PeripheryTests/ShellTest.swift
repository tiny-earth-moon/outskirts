//
//  ShellTest.swift
//  Periphery
//
//  Created by Alexander Goodkind on 2026-10-25.
//

import Foundation
import Logger
@testable import Shared
import Synchronization
import XCTest

final class ShellTest: XCTestCase {
    func testCapturesLargeOutputFromBothStreams() throws {
        let shell = ShellImpl(logger: Logger(quiet: true, verbose: false, colorMode: .never))
        let output = try shell.exec(command(status: 0))
        XCTAssertEqual(output, "stdout:\(String(repeating: "x", count: 262_144)):end")
    }

    func testPreservesBothStreamsOnFailure() throws {
        let shell = ShellImpl(logger: Logger(quiet: true, verbose: false, colorMode: .never))
        let command = command(status: 7)

        XCTAssertThrowsError(try shell.exec(command)) { error in
            guard case let PeripheryError.shellCommandFailed(cmd, status, output) = error else {
                return XCTFail("Expected a shell command failure, received \(error)")
            }

            XCTAssertEqual(cmd, command)
            XCTAssertEqual(status, 7)
            let payload = String(repeating: "x", count: 262_144)
            XCTAssertEqual(output, "stdout:\(payload):end\nstderr:\(payload):end")
        }
    }

    func testInvalidUTF8OnStderr_doesNotFailSuccessfulCommand() throws {
        let shell = ShellImpl(logger: Logger(quiet: true, verbose: false, colorMode: .never))
        let output = try shell.exec(["/bin/sh", "-c", "printf 'caf\\351' >&2; printf ok"])
        XCTAssertEqual(output, "ok")
    }

    func testInvalidUTF8_failedCommandKeepsOutput() {
        let shell = ShellImpl(logger: Logger(quiet: true, verbose: false, colorMode: .never))

        XCTAssertThrowsError(try shell.exec(["/bin/sh", "-c", "printf 'caf\\351 broke' >&2; exit 3"])) { error in
            guard case let PeripheryError.shellCommandFailed(_, status, output) = error else {
                return XCTFail("Expected a shell command failure, received \(error)")
            }

            XCTAssertEqual(status, 3)
            XCTAssertEqual(output, "caf\u{FFFD} broke")
        }
    }

    func testSignalTermination_isReportedAsSignal() {
        let shell = ShellImpl(logger: Logger(quiet: true, verbose: false, colorMode: .never))

        XCTAssertThrowsError(try shell.exec(["/bin/sh", "-c", "echo partial; kill -9 $$"])) { error in
            guard case let PeripheryError.shellCommandKilled(_, signal, output) = error else {
                return XCTFail("Expected a killed shell command, received \(error)")
            }

            XCTAssertEqual(signal, SIGKILL)
            XCTAssertEqual(output, "partial")
            XCTAssertTrue(error.localizedDescription.contains("killed by signal 9 (SIGKILL), possibly out of memory"))
        }
    }

    func testStopRunning_ignoresUnlaunchedProcess() {
        let store = ShellProcessStore()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["5"]
        store.add(process)

        store.stopRunning(signal: SIGINT)

        XCTAssertTrue(store.isStopping)
        XCTAssertFalse(process.isRunning)
    }

    func testCancellation_runsTheHooksOnceTheProcessesHaveStopped() throws {
        let store = ShellProcessStore()
        let hooks = CancellationHooks()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        store.add(process)
        let events = Mutex<[String]>([])
        hooks.add { events.withLock { $0.append("hook, build running: \(process.isRunning)") } }

        let status = ShellImpl.cancel(signal: SIGINT, sigintHandler: { events.withLock { $0.append("handler") } }, store: store, hooks: hooks)

        XCTAssertEqual(status, 130)
        XCTAssertEqual(events.withLock { $0 }, ["handler", "hook, build running: false"])
        XCTAssertEqual(ShellImpl.cancel(signal: SIGTERM, sigintHandler: {}, store: ShellProcessStore(), hooks: CancellationHooks()), 143)
    }

    func testPassesArgumentsLiterallyWithoutAShell() throws {
        let shell = ShellImpl(logger: Logger(quiet: true, verbose: false, colorMode: .never))
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("periphery-shell-\(UUID().uuidString)")
        let hostile = "$(touch \(marker.path)) `touch \(marker.path)` 'single' \"double\" a\\b; echo injected"

        let output = try shell.exec(["printf", "%s|%s", hostile, "two words"])

        XCTAssertEqual(output, "\(hostile)|two words")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testResolvesExecutableFromPath() throws {
        let url = try ShellImpl.executableURL(for: "printf", environment: ["PATH": "/nonexistent::/usr/bin:/bin"])
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: url.path))
        XCTAssertEqual(url.lastPathComponent, "printf")
        XCTAssertEqual(try ShellImpl.executableURL(for: "/bin/echo", environment: [:]).path, "/bin/echo")
    }

    func testThrowsWhenExecutableIsNotInPath() {
        XCTAssertThrowsError(try ShellImpl.executableURL(for: "periphery-no-such-tool", environment: ["PATH": "/usr/bin"])) { error in
            guard case let PeripheryError.executableNotFound(name, searchPath) = error else {
                return XCTFail("Expected executableNotFound, received \(error)")
            }

            XCTAssertEqual(name, "periphery-no-such-tool")
            XCTAssertEqual(searchPath, ["/usr/bin"])
        }
    }

    func testShellQuotedRendersCommandForDisplay() {
        XCTAssertEqual(
            ["xcodebuild", "-scheme", "My $(App)", "it's", ""].shellQuoted,
            "xcodebuild -scheme 'My $(App)' 'it'\\''s' ''"
        )
    }

    private func command(status: Int) -> [String] {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ShellOutput.sh")
        return ["/bin/bash", fixture.path, String(status)]
    }
}
