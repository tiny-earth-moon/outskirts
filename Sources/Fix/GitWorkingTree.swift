import Foundation
import Shared
import Synchronization
import SystemPackage

/// Reads the uncommitted files of the git working tree that holds a directory. git is run with an argument array,
/// never through a shell.
public enum GitWorkingTree {
    /// Throws when git fails for another reason than the directory being outside any working tree.
    public static func state(at directory: FilePath) throws -> WorkingTreeState {
        do {
            return try readState(at: directory)
        } catch let error as GitWorkingTreeError {
            throw PeripheryError.underlyingError(error)
        }
    }

    /// The real path of the top level of the working tree that holds the directory, nil outside any working tree.
    /// Throws when git fails for another reason.
    static func topLevel(of directory: FilePath) throws -> String? {
        let output: String
        do {
            output = try run(["rev-parse", "--show-toplevel"], in: directory)
        } catch let GitWorkingTreeError.failed(_, _, message) where message.contains(notARepositoryMessage) {
            return nil
        }

        let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { throw GitWorkingTreeError.failed(command: "rev-parse --show-toplevel", status: 0, message: "no top level") }

        return RealPath.resolve(path)
    }

    // MARK: - Private

    private static func readState(at directory: FilePath) throws -> WorkingTreeState {
        guard let root = try topLevel(of: directory) else { return .notARepository }

        let status = try run(["status", "--porcelain=v1", "-z", "--untracked-files=all", "--no-renames"], in: directory)
        let paths = status.split(separator: "\0").compactMap { entry -> String? in
            guard entry.count > 3 else { return nil }

            return RealPath.resolve(root + "/" + entry.dropFirst(3))
        }
        // git does not track a file through a linked directory, so the paths of the index are real paths.
        let tracked = try run(["ls-files", "-z", "--full-name"], in: FilePath(root))
            .split(separator: "\0")
            .map { root + "/" + $0 }
        return .repository(topLevel: root, uncommitted: Set(paths), tracked: Set(tracked))
    }

    /// What git prints, in the C locale, when no parent of the directory is a working tree. An explicit `GIT_DIR` that
    /// does not exist prints `not a git repository: '<path>'` instead, which is a failure.
    private static let notARepositoryMessage = "not a git repository (or any"

    /// The standard output of git; throws when it exits with a non-zero status, with what it printed on standard error.
    private static func run(_ arguments: [String], in directory: FilePath) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", directory.string] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        process.environment = environment
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        // Both pipes are read at once, so that neither fills up while git waits to write to the other.
        let handles = [output.fileHandleForReading, error.fileHandleForReading]
        let results = Mutex<[Result<Data?, Error>]>([.success(nil), .success(nil)])
        let reads = DispatchGroup()
        for (index, handle) in handles.enumerated() {
            DispatchQueue.global().async(group: reads) {
                let result = Result { try handle.readToEnd() }
                results.withLock { $0[index] = result }
            }
        }
        reads.wait()
        process.waitUntilExit()

        let data = try results.withLock { try $0[0].get() } ?? Data()
        let errorData = try results.withLock { try $0[1].get() } ?? Data()
        let command = arguments.joined(separator: " ")
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitWorkingTreeError.failed(command: command, status: process.terminationStatus, message: message)
        }
        guard let string = String(bytes: data, encoding: .utf8) else {
            throw GitWorkingTreeError.failed(command: command, status: 0, message: "the output is not UTF-8")
        }

        return string
    }
}

enum GitWorkingTreeError: Error, CustomStringConvertible {
    case failed(command: String, status: Int32, message: String)

    var description: String {
        switch self {
        case let .failed(command, status, message):
            "git \(command) failed with status \(status): \(message)"
        }
    }
}
