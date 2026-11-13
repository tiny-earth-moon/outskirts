import Extensions
import Foundation
import Synchronization
import SystemPackage

/// Runs git with an argument array, never through a shell, in the C locale.
public enum Git {
    /// The real path of the top level of the working tree that holds the directory, nil outside any working tree.
    /// Throws when git fails for another reason.
    public static func topLevel(of directory: FilePath) throws -> String? {
        let output: String
        do {
            output = try run(["rev-parse", "--show-toplevel"], in: directory)
        } catch let GitError.failed(_, _, message) where message.contains(notARepositoryMessage) {
            return nil
        }

        let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { throw GitError.failed(command: "rev-parse --show-toplevel", status: 0, message: "no top level") }

        return RealPath.resolve(path)
    }

    /// The standard output of git; throws when it exits with a non-zero status, with what it printed on standard error.
    public static func run(_ arguments: [String], in directory: FilePath) throws -> String {
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
            let message = String(bytes: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? "standard error is not UTF-8"
            throw GitError.failed(command: command, status: process.terminationStatus, message: message)
        }
        guard let string = String(bytes: data, encoding: .utf8) else {
            throw GitError.failed(command: command, status: 0, message: "the output is not UTF-8")
        }

        return string
    }

    // MARK: - Private

    /// What git prints, in the C locale, when no parent of the directory is a working tree. An explicit `GIT_DIR` that
    /// does not exist prints `not a git repository: '<path>'` instead, which is a failure.
    private static let notARepositoryMessage = "not a git repository (or any"
}

public enum GitError: Error, CustomStringConvertible {
    case failed(command: String, status: Int32, message: String)

    public var description: String {
        switch self {
        case let .failed(command, status, message):
            "git \(command) failed with status \(status): \(message)"
        }
    }
}

public enum RealPath {
    public static func resolve(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }

        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// The path of the file relative to the root when the file lies inside it, compared as written first, then with
    /// both sides resolved, so that a link or `/tmp` against `/private/tmp` does not take the file out of the root.
    public static func relativePath(of file: FilePath, within root: FilePath) -> FilePath? {
        if let relative = lexicallyContained(file, in: root) {
            return relative
        }

        return lexicallyContained(FilePath(resolve(file.string)), in: FilePath(resolve(root.string)))
    }

    private static func lexicallyContained(_ file: FilePath, in root: FilePath) -> FilePath? {
        let relative = file.relativeTo(root)
        guard relative.components.first?.string != ".." else { return nil }

        return relative
    }
}
