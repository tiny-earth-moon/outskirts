import Foundation
import XCTest

/// The exit status and the full standard output and error of a finished process.
public struct CapturedProcessOutput {
    public let status: Int32
    public let stdout: Data
    public let stderr: Data
}

/// Runs `executableURL` to completion, capturing stdout and stderr through files in `outputDirectory` (pipes could fill up and block the child).
/// With a `timeout`, the process is killed and the test fails once it has elapsed.
public func runCapturingOutput(
    _ executableURL: URL,
    _ arguments: [String],
    currentDirectoryURL: URL? = nil,
    outputDirectory: URL,
    timeout: (seconds: Int, name: String)? = nil,
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> CapturedProcessOutput {
    let stdoutFile = outputDirectory.appendingPathComponent("stdout.txt")
    let stderrFile = outputDirectory.appendingPathComponent("stderr.txt")
    FileManager.default.createFile(atPath: stdoutFile.path, contents: nil)
    FileManager.default.createFile(atPath: stderrFile.path, contents: nil)
    defer {
        try? FileManager.default.removeItem(at: stdoutFile)
        try? FileManager.default.removeItem(at: stderrFile)
    }

    let exited = DispatchSemaphore(value: 0)
    let process = Process()
    process.executableURL = executableURL
    process.arguments = arguments
    if let currentDirectoryURL {
        process.currentDirectoryURL = currentDirectoryURL
    }
    process.standardOutput = try FileHandle(forWritingTo: stdoutFile)
    process.standardError = try FileHandle(forWritingTo: stderrFile)
    process.terminationHandler = { _ in exited.signal() }
    try process.run()

    if let timeout {
        if exited.wait(timeout: .now() + .seconds(timeout.seconds)) == .timedOut {
            kill(process.processIdentifier, SIGKILL)
            XCTFail("\(timeout.name) did not exit within \(timeout.seconds)s", file: file, line: line)
        }
    } else {
        exited.wait()
    }
    process.waitUntilExit()

    return try CapturedProcessOutput(
        status: process.terminationStatus,
        stdout: Data(contentsOf: stdoutFile),
        stderr: Data(contentsOf: stderrFile)
    )
}
