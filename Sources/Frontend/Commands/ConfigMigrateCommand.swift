import ArgumentParser
import Configuration
import Foundation
import Shared
import SystemPackage

struct ConfigMigrateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "migrate",
        abstract: "Print the configuration file rewritten in the format 2 ('version: 2'), which loads into the same configuration; the default 'index_exclude' globs are written out, comments are kept"
    )

    @OptionGroup
    var locationOptions: ProjectLocationOptions

    @Flag(help: "Write the migrated configuration over the file instead of printing it")
    var apply: Bool = false

    func run() throws {
        let projectRoot = try locationOptions.changeToProjectRoot()

        guard let path = try Configuration().configurationPath(withUserProvided: locationOptions.config) else {
            let names = Configuration.configurationFileNames.joined(separator: ", ")
            throw PeripheryError.usageError("No configuration file in '\(projectRoot.string)' (looked for \(names)), pass one with '--config'.")
        }

        let migrated = try Configuration.migratedToV2(file: path)

        if apply {
            let written = try write(migrated, to: path, projectRoot: projectRoot)
            let through = written == path ? "" : " (through the symbolic link, to \(written.string))"
            FileHandle.standardError.write(Data("\(path.string): migrated to version 2\(through)\n".utf8))
        } else {
            print(migrated, terminator: "")
        }
    }

    /// A file named with `--config` is written where it leads, through a symbolic link too. The file found in the
    /// project root is written at its real path, which must stay inside the project root.
    private func write(_ migrated: String, to path: FilePath, projectRoot: FilePath) throws -> FilePath {
        let data = Data(migrated.utf8)
        guard locationOptions.config == nil else {
            return try OutputFile.write(data, to: path)
        }

        let isLink = OutputFile.isSymbolicLink(path.string)
        do {
            let written = try OutputFile.writeConfined(data, to: path, within: projectRoot)
            return isLink ? written : path
        } catch let PeripheryError.usageError(message) {
            throw PeripheryError.usageError("\(message) Pass the file it leads to with '--config' to migrate it there.")
        }
    }
}
