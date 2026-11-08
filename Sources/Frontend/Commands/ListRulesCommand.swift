import ArgumentParser
import Configuration
import Foundation

struct ListRulesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list-rules",
        abstract: "List every rule: its id, whether it is checked by default, and the key that turns it on or off in a configuration file of each format"
    )

    enum Format: String, CaseIterable, ExpressibleByArgument {
        case text
        case json
    }

    @Option(help: "Output format: \(Format.allCases.map(\.rawValue).joined(separator: ", ")) (default: text)")
    var format: Format = .text

    func run() throws {
        switch format {
        case .text:
            print(Self.text(), terminator: "")
        case .json:
            print(try Self.json())
        }
    }

    /// One line per rule, in columns.
    static func text() -> String {
        let rows = [["RULE", "DEFAULT", "V2 KEY", "V1 KEY"]] + RuleIdentifier.allCases.map { rule in
            [rule.rawValue, rule.isEnabledByDefault ? "on" : "off", rule.v2Path, v1Description(of: rule)]
        }
        let widths = (0 ..< 3).map { column in rows.map { $0[column].count }.max() ?? 0 }

        return rows.map { row in
            row.enumerated().map { column, value in
                column < widths.count ? value.padding(toLength: widths[column] + 2, withPad: " ", startingAt: 0) : value
            }.joined()
        }.joined(separator: "\n") + "\n"
    }

    static func json() throws -> String {
        let rules = RuleIdentifier.allCases.map { rule in
            Rule(
                id: rule.rawValue,
                enabledByDefault: rule.isEnabledByDefault,
                v2Key: rule.v2Path,
                v1Key: rule.v1Key,
                v1KeyTurnsRuleOff: rule.v1Key == nil ? nil : rule.v1KeyTurnsRuleOff,
                overridable: rule.isOverridable
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        guard let json = try String(bytes: encoder.encode(rules), encoding: .utf8) else {
            preconditionFailure("JSONEncoder wrote invalid UTF-8")
        }

        return json
    }

    // MARK: - Private

    private struct Rule: Encodable {
        let id: String
        let enabledByDefault: Bool
        let v2Key: String
        let v1Key: String?
        let v1KeyTurnsRuleOff: Bool?
        let overridable: Bool

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: RuleCodingKey.self)
            try container.encode(id, forKey: .id)
            try container.encode(enabledByDefault, forKey: .enabledByDefault)
            try container.encode(v2Key, forKey: .v2Key)
            // `null` when the rule is always checked, rather than a missing key.
            try container.encode(v1Key, forKey: .v1Key)
            try container.encode(v1KeyTurnsRuleOff, forKey: .v1KeyTurnsRuleOff)
            try container.encode(overridable, forKey: .overridable)
        }
    }

    private static func v1Description(of rule: RuleIdentifier) -> String {
        guard let key = rule.v1Key else { return "- (always checked)" }

        return rule.v1KeyTurnsRuleOff ? "\(key) (true turns it off)" : key
    }
}

private enum RuleCodingKey: String, CodingKey {
    case id
    case enabledByDefault
    case v2Key
    case v1Key
    case v1KeyTurnsRuleOff
    case overridable
}
