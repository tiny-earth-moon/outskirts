import ArgumentParser
import Configuration

struct ConfigCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Check, print or migrate the configuration file, or print its JSON Schema",
        subcommands: [ConfigCheckCommand.self, ConfigPrintCommand.self, ConfigMigrateCommand.self, ConfigSchemaCommand.self]
    )
}

struct ConfigSchemaCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "schema",
        abstract: "Print the JSON Schema (draft-07) of the configuration file"
    )

    func run() throws {
        print(Configuration().jsonSchema(), terminator: "")
    }
}
