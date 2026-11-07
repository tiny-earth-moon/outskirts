import ArgumentParser
import CStdio
import Foundation
import Shared

/// When stdout is a pipe, enable line buffering so output is flushed after each
/// newline rather than block-buffered, ensuring timely output to the consumer.
var info = stat()
fstat(STDOUT_FILENO, &info)

if (info.st_mode & S_IFMT) == S_IFIFO {
    setlinebuf(periphery_stdout())
    setlinebuf(periphery_stderr())
}

struct OutskirtsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "outskirts",
        version: PeripheryVersion,
        subcommands: [
            ScanCommand.self,
            FixCommand.self,
            CheckUpdateCommand.self,
            ClearCacheCommand.self,
            ConfigCommand.self,
            VersionCommand.self,
        ]
    )
}

do {
    var command = try OutskirtsCommand.parseAsRoot()
    try command.run()
} catch {
    let parserCode = OutskirtsCommand.exitCode(for: error).rawValue
    let code = ExitStatus.code(for: error, parserCode: parserCode, mode: ExitCodes.selected)

    if code != parserCode {
        let message = OutskirtsCommand.fullMessage(for: error)
        if !message.isEmpty {
            FileHandle.standardError.write(Data((message + "\n").utf8))
        }
        exit(code)
    }

    OutskirtsCommand.exit(withError: error)
}
