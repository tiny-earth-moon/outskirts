import ArgumentParser
import Configuration
import Foundation
import Shared

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
            try migrated.write(to: path.url, atomically: true, encoding: .utf8)
            FileHandle.standardError.write(Data("\(path.string): migrated to version 2\n".utf8))
        } else {
            print(migrated, terminator: "")
        }
    }
}
