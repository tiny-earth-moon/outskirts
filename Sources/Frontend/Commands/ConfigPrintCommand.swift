import ArgumentParser
import Configuration
import Foundation
import Logger

struct ConfigPrintCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "print",
        abstract: "Print the configuration in effect, as YAML in the format of the file: the options that differ from their default, the files a 'version: 2' file extends merged in, and its overrides"
    )

    @OptionGroup
    var locationOptions: ProjectLocationOptions

    @Flag(help: "Also print the options left at their default")
    var all: Bool = false

    func run() throws {
        _ = try locationOptions.changeToProjectRoot()

        let configuration = Configuration()
        var warnings: [String] = []
        try configuration.load(from: locationOptions.config) { warnings.append($0) }
        let logger = Logger(quiet: false, verbose: false, colorMode: .auto, messagesToStderr: true)
        warnings.forEach { logger.warn($0) }

        print(try configuration.effectiveYAML(all: all), terminator: "")
    }
}
