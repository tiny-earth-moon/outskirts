import Foundation
import Logger
import Synchronization

final class ShellProcessStore: Sendable {
    private let processes = Mutex<Set<Process>>([])
    private let stopping = Mutex<Bool>(false)

    /// Whether the running processes have been told to stop, in which case the program is about to exit.
    var isStopping: Bool {
        stopping.withLock { $0 }
    }

    /// Interrupts (`SIGINT`) or terminates (`SIGTERM`) the running processes and waits for them to exit.
    func stopRunning(signal: Int32) {
        stopping.withLock { $0 = true }
        processes.withLock { processes in
            for process in processes where process.isRunning {
                if signal == SIGINT {
                    process.interrupt()
                } else {
                    process.terminate()
                }
                process.waitUntilExit()
            }
        }
    }

    func add(_ process: Process) {
        processes.withLock { _ = $0.insert(process) }
    }

    func remove(_ process: Process) {
        processes.withLock { _ = $0.remove(process) }
    }
}

public protocol Shell: Sendable {
    @discardableResult
    func exec(_ args: [String]) throws -> String
}

public final class ShellImpl: Shell {
    private let logger: ContextualLogger
    private let store: ShellProcessStore
    // outskirts:ignore - assign-only on purpose: holding the sources keeps the signal handlers installed
    /// Only kept alive here, never read; the `Mutex` makes the class `Sendable` on Linux, where
    /// `DispatchSourceSignal` is not.
    private let signalSources: Mutex<[DispatchSourceSignal]>

    /// `sigintHandler` runs when `SIGINT` or `SIGTERM` is received, before the running processes are stopped. The
    /// program then exits with the conventional status of the signal, 130 for `SIGINT` and 143 for `SIGTERM`.
    public required init(logger: Logger, sigintHandler: @escaping @Sendable () -> Void = {}) {
        self.logger = logger.contextualized(with: "shell")
        store = ShellProcessStore()

        let sources = [SIGINT, SIGTERM].map { [store] signalNumber in
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global())
            source.setEventHandler {
                sigintHandler()
                store.stopRunning(signal: signalNumber)
                exit(128 + signalNumber)
            }
            source.resume()
            return source
        }
        signalSources = Mutex(sources)
    }

    @discardableResult
    public func exec(_ args: [String]) throws -> String {
        let (status, reason, stdout, stderr) = try exec(args)

        if reason == .exit, status == 0 {
            return stdout
        }

        let output = [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n").trimmed
        if reason == .uncaughtSignal {
            throw PeripheryError.shellCommandKilled(cmd: args, signal: status, output: output)
        }
        throw PeripheryError.shellCommandFailed(cmd: args, status: status, output: output)
    }

    // MARK: - Private

    private func exec(_ cmd: [String]) throws -> (Int32, Process.TerminationReason, String, String) {
        guard let executable = cmd.first else {
            throw PeripheryError.executableNotFound(name: "", searchPath: [])
        }

        let process = Process()
        process.executableURL = try Self.executableURL(
            for: executable,
            environment: ProcessInfo.processInfo.environment
        )
        process.arguments = Array(cmd.dropFirst())

        logger.debug(cmd.shellQuoted)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        store.add(process)
        defer { store.remove(process) }

        var standardOutput = ""
        var standardError = ""

        let handles = [stdoutPipe.fileHandleForReading, stderrPipe.fileHandleForReading]
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

        if store.isStopping {
            // The signal handler is about to exit with the status of the signal, don't race it with a failure.
            Self.parkUntilExit()
        }

        // Decoded leniently: a stray non UTF-8 byte, such as a Latin-1 path in a compiler warning, must neither
        // fail a successful command nor hide the output of a failed one.
        if let stdoutData = try results.withLock({ try $0[0].get() }) {
            // swiftlint:disable:next optional_data_string_conversion
            standardOutput = String(decoding: stdoutData, as: UTF8.self)
        }

        if let stderrData = try results.withLock({ try $0[1].get() }) {
            // swiftlint:disable:next optional_data_string_conversion
            standardError = String(decoding: stderrData, as: UTF8.self)
        }

        return (process.terminationStatus, process.terminationReason, standardOutput, standardError)
    }

    private static func parkUntilExit() -> Never {
        while true {
            sleep(60)
        }
    }

    /// Resolves the executable of a command without a shell: a name containing a slash is used as a path,
    /// any other name is looked up in the `PATH` of the given environment.
    static func executableURL(for name: String, environment: [String: String]) throws -> URL {
        if name.contains("/") {
            return URL(fileURLWithPath: name)
        }

        let searchPath = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
            .filter { !$0.isEmpty }

        for directory in searchPath {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
               !isDirectory.boolValue,
               FileManager.default.isExecutableFile(atPath: candidate.path)
            {
                return candidate
            }
        }

        throw PeripheryError.executableNotFound(name: name, searchPath: searchPath)
    }
}

public extension [String] {
    /// A human-readable, shell-quoted rendering of a command, for display only. Commands are never run through a shell.
    var shellQuoted: String {
        map(\.shellQuotedArgument).joined(separator: " ")
    }
}

public extension String {
    /// The string as a single shell word: unchanged if it only contains safe characters, single-quoted otherwise.
    var shellQuotedArgument: String {
        let safeCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@%+=:,./_-")
        if !isEmpty, unicodeScalars.allSatisfy({ safeCharacters.contains($0) }) {
            return self
        }
        return "'" + replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
