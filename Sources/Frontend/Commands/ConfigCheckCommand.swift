import ArgumentParser
import Configuration
import Foundation
import Logger
import Shared
import SystemPackage

struct ConfigCheckCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "check",
        abstract: "Check the configuration file without scanning: unknown keys, values of the wrong type (with their line in a 'version: 2' file), invalid 'report_exclude' and 'retain_attributes' entries, options missing the option they require, baseline and output paths. Exits with status 1 on any problem"
    )

    @OptionGroup
    var locationOptions: ProjectLocationOptions

    func run() throws {
        let projectRoot = try locationOptions.changeToProjectRoot()

        let configuration = Configuration()

        guard let path = try configuration.configurationPath(withUserProvided: locationOptions.config) else {
            let names = Configuration.configurationFileNames.joined(separator: ", ")
            throw PeripheryError.usageError("No configuration file in '\(projectRoot.string)' (looked for \(names)), pass one with '--config'.")
        }

        let logger = Logger(quiet: false, verbose: false, colorMode: .auto, messagesToStderr: true)
        var warnings: [String] = []
        let errors: [String]

        // The load of the scan, whose errors for a `version: 2` file are the scan's own; the scan checks the options
        // only once the file is valid.
        do {
            try configuration.load(from: path) { warnings.append($0) }
            errors = ScanPreflight.problems(in: configuration)
        } catch let error as ConfigurationFileError {
            errors = error.problems
        }

        warnings.forEach { logger.warn($0) }
        errors.forEach { logger.error($0) }

        let count = warnings.count + errors.count

        guard count > 0 else {
            print("\(path.string): ok")
            return
        }

        logger.error("\(path.string): \(count) \(count > 1 ? "problems" : "problem") found")
        throw ExitCode.failure
    }
}
