import ArgumentParser
import Configuration
import Foundation
@testable import Frontend
import Shared
import XCTest

/// Periphery 3.8 compatibility contract for the command line: every 3.8 subcommand and `scan` option is still accepted,
/// with the same names and value kind, and the parse errors keep their exit status.
///
/// A failing test here is a 3.x compatibility break that needs a deliberate decision, not a fixture or test update.
final class Periphery38CLIContractTest: XCTestCase {
    private var cli: Contract38CLI!

    override func setUpWithError() throws {
        try super.setUpWithError()
        cli = try Periphery38Contract.decode(Contract38CLI.self, from: "cli.json")
    }

    func testEverySubcommandOf38IsStillAvailable() throws {
        let commands = try dumpedRoot().subcommands ?? []

        for command in cli.commands {
            let current = commands.first { $0.commandName == command.name }
            XCTAssertNotNil(current, "the 3.8 subcommand '\(command.name)' is gone")
            for argument in command.arguments where argument.kind != "positional" {
                XCTAssertNotNil(current?.argument(named: argument.names[0]), "'\(command.name) \(argument.names[0])' is gone")
            }
        }

        for name in cli.commands.map(\.name) where name != "help" {
            let parsed = try OutskirtsCommand.parseAsRoot([name])
            XCTAssertEqual(type(of: parsed).configuration.commandName, name)
        }
    }

    func testEveryScanArgumentOf38KeepsItsNamesAndValueKind() throws {
        let scan = try XCTUnwrap(cli.command("scan"))
        let current = try XCTUnwrap(dumpedRoot().subcommands?.first { $0.commandName == "scan" })

        XCTAssertEqual(scan.arguments.count, 55, "the 3.8 fixture lists 54 options and the build arguments")

        for argument in scan.arguments {
            let match: DumpedArgument? = if argument.kind == "positional" {
                current.arguments?.first { $0.kind == "positional" }
            } else {
                current.argument(named: argument.names[0])
            }
            guard let match else {
                XCTFail("the 3.8 scan argument \(argument.names.first ?? argument.valueName ?? "?") is gone")
                continue
            }

            let label = argument.names.first ?? "<\(argument.valueName ?? "")>"
            XCTAssertEqual(Set(argument.names).subtracting(match.spelledNames), [], "\(label) lost a name")
            XCTAssertEqual(match.kind, argument.kind, "\(label) changed its kind")
            XCTAssertEqual(match.isRepeating, argument.repeating, "\(label) changed between a single and a repeated value")
            XCTAssertEqual(match.parsingStrategy ?? "default", argument.parsing, "\(label) changed how its values are read")
            if let values = argument.values {
                XCTAssertEqual(Set(values).subtracting(match.allValues ?? []), [], "\(label) no longer accepts some 3.8 values")
            }
        }
    }

    func testEveryScanOptionOf38StillParsesAndReachesTheConfiguration() throws {
        let scan = try XCTUnwrap(cli.command("scan"))
        let handledOutsideTheConfiguration: Set = ["--setup", "--project-root", "--config", "--superfluous-ignore-comments", "-h"]
        var checked = 0

        for argument in scan.arguments where argument.kind != "positional" && argument.hidden != true {
            let name = argument.names[0]
            guard !Self.removedBazelOptions.contains(name), !handledOutsideTheConfiguration.contains(name) else { continue }

            let command = try ScanCommand.parse(Self.arguments(for: argument))
            let configuration = Configuration()
            command.apply(to: configuration)
            XCTAssertNotEqual(try configuration.asYaml(), try Configuration().asYaml(), "\(name) no longer reaches the configuration")
            checked += 1
        }

        XCTAssertEqual(checked, 43)
    }

    func testHiddenNoColorOf38StillParses() throws {
        let argument = try XCTUnwrap(cli.command("scan")?.arguments.first { $0.names == ["--no-color"] })
        XCTAssertEqual(argument.hidden, true)

        let configuration = Configuration()
        try ScanCommand.parse(["--no-color"]).apply(to: configuration)
        XCTAssertEqual(configuration.color, .never)
    }

    func testOptionsHandledOutsideTheConfigurationStillParse() throws {
        let command = try ScanCommand.parse(["--setup", "--project-root", "/tmp/root", "--config", "custom.yml"])
        XCTAssertTrue(command.projectOptions.setup)
        XCTAssertEqual(command.projectOptions.projectRoot?.string, "/tmp/root")
        XCTAssertEqual(command.projectOptions.config?.string, "custom.yml")

        let configuration = Configuration()
        configuration.superfluousIgnoreComments = false
        try ScanCommand.parse(["--superfluous-ignore-comments"]).apply(to: configuration)
        XCTAssertTrue(configuration.superfluousIgnoreComments)
    }

    func testBuildArgumentsAfterTheSeparatorStillReachTheBuildTool() throws {
        let configuration = Configuration()
        try ScanCommand.parse(["--strict", "--", "-c", "release"]).apply(to: configuration)
        XCTAssertEqual(configuration.buildArguments, ["-c", "release"])
    }

    /// 3.8 ran the Bazel mode; it was removed in 3.13.0. The options are still recognised, so that
    /// they fail with an explicit message and exit status 1 instead of an unknown option error.
    func testRemovedBazelOptionsOf38FailWithTheRemovalMessage() throws {
        let scan = try XCTUnwrap(cli.command("scan"))
        let bazel = scan.arguments.filter { $0.names.first.map(Self.removedBazelOptions.contains) == true }
        XCTAssertEqual(bazel.count, Self.removedBazelOptions.count)

        for argument in bazel {
            XCTAssertThrowsError(try OutskirtsCommand.parseAsRoot(["scan"] + Self.arguments(for: argument))) { error in
                XCTAssertTrue(OutskirtsCommand.message(for: error).contains("Bazel support was removed in 3.13.0"), "\(argument.names[0])")
                XCTAssertEqual(OutskirtsCommand.exitCode(for: error).rawValue, 1, "\(argument.names[0])")
            }
        }
    }

    func testParseErrorsKeepTheExitStatusOf38() throws {
        let codes = try Periphery38Contract.decode(Contract38ExitCodes.self, from: "exit-codes.json")

        XCTAssertEqual(parseExitStatus(["scan", "--not-an-option"]), codes.scan.unknownOption)
        XCTAssertEqual(parseExitStatus(["scan", "--format", "not-a-format"]), codes.scan.invalidOptionValue)
        XCTAssertEqual(parseExitStatus(["scan", "--color", "sometimes"]), codes.scan.invalidOptionValue)
        XCTAssertEqual(parseExitStatus(["not-a-command"]), codes.unknownSubcommand)
    }

    func testScanErrorsKeepTheExitStatusOf38() throws {
        let codes = try Periphery38Contract.decode(Contract38ExitCodes.self, from: "exit-codes.json")

        XCTAssertEqual(OutskirtsCommand.exitCode(for: PeripheryError.foundIssues(count: 1)).rawValue, codes.scan.resultsWithStrict)
        XCTAssertEqual(OutskirtsCommand.exitCode(for: PeripheryError.pathDoesNotExist(path: "missing.yml")).rawValue, codes.scan.missingConfigurationFile)
    }

    // MARK: - Private

    private static let removedBazelOptions: Set = ["--bazel", "--bazel-filter", "--bazel-query", "--bazel-index-store", "--bazel-check-visibility"]

    /// A valid use of the option: the flag alone, or the option with one value, or two for a repeated option.
    private static func arguments(for argument: Contract38Argument) -> [String] {
        let name = argument.names[0]

        switch (argument.kind, argument.repeating) {
        case ("flag", _):
            return [name]
        case (_, true):
            return [name, "First/**", "Second/**"]
        default:
            return [name, argument.values?.last ?? "value.json"]
        }
    }

    private func parseExitStatus(_ arguments: [String]) -> Int32? {
        do {
            _ = try OutskirtsCommand.parseAsRoot(arguments)
            XCTFail("\(arguments) parsed")
            return nil
        } catch {
            return OutskirtsCommand.exitCode(for: error).rawValue
        }
    }

    private func dumpedRoot() throws -> DumpedCommand {
        try JSONDecoder().decode(DumpedHelp.self, from: Data(OutskirtsCommand._dumpHelp().utf8)).command
    }
}

/// The parts of ArgumentParser's `--experimental-dump-help` that the contract compares.
private struct DumpedHelp: Decodable {
    let command: DumpedCommand
}

private struct DumpedCommand: Decodable {
    let commandName: String
    let arguments: [DumpedArgument]?
    let subcommands: [DumpedCommand]?

    func argument(named name: String) -> DumpedArgument? {
        arguments?.first { $0.spelledNames.contains(name) }
    }
}

private struct DumpedArgument: Decodable {
    struct Name: Decodable {
        let kind: String
        let name: String
    }

    let kind: String
    let names: [Name]?
    let isRepeating: Bool
    let parsingStrategy: String?
    let allValues: [String]?

    var spelledNames: Set<String> {
        Set((names ?? []).map { (["short", "longWithSingleDash"].contains($0.kind) ? "-" : "--") + $0.name })
    }
}
