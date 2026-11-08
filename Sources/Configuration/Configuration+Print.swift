import Foundation
import Shared
import Yams

public extension Configuration {
    /// The configuration in effect after the last load, as YAML in the format of the file: the settings that differ
    /// from their default, or every setting with `all`. A v2 configuration names the files it was read from and lists
    /// its `overrides`; its globs are shown absolute, as they were resolved from the directory of their file.
    func effectiveYAML(all: Bool) throws -> String {
        var values: [String: Node] = [:]
        for setting in settings where all || differsFromDefault(setting) {
            values[setting.key] = try Self.node(of: setting.key == $indexExclude.key ? indexExclude.sorted() : setting.wrappedValue)
        }

        guard loadedVersion == 2 else {
            let lines = try settingKeys.compactMap { key in
                try values[key].map { try ConfigurationV2Writer.render(key: key, value: $0) }
            }
            return lines.joined().map { $0 + "\n" }.joined()
        }

        if values[$indexExclude.key] != nil {
            values[ConfigurationV2Writer.indexDefaultsKey] = Node("false", .implicit, .plain)
        }

        var comments = ConfigurationV2Writer.Comments()
        if !loadedFiles.isEmpty {
            comments.header = ["# Read from \(loadedFiles.map(\.string).joined(separator: ", then "))"]
        }

        return try ConfigurationV2Writer.render(ConfigurationV2Writer.entries(fromV1Values: values), comments: comments, trailing: overridesYAML())
    }

    // MARK: - Private

    private func differsFromDefault(_ setting: any AbstractSetting) -> Bool {
        if setting.key == $indexExclude.key {
            return Set(indexExclude) != Set($indexExclude.defaultValue)
        }
        return setting.hasNonDefaultValue
    }

    private func overridesYAML() throws -> [String] {
        guard !overrides.isEmpty else { return [] }

        let entries = overrides.map { entry in
            var pairs: [(Node, Node)] = []
            if !entry.modules.isEmpty {
                pairs.append((Node("modules"), Self.flowList(entry.modules)))
            }
            if !entry.paths.isEmpty {
                pairs.append((Node("paths"), Self.flowList(entry.paths)))
            }
            let retain = [("public", entry.retainPublic), ("all", entry.retainAll)].compactMap { key, value in
                value.map { (Node(key), Node($0 ? "true" : "false", .implicit, .plain)) }
            }
            if !retain.isEmpty {
                pairs.append((Node("retain"), Node.mapping(.init(retain, .implicit, .flow))))
            }
            let rules = RuleIdentifier.allCases.compactMap { rule in
                entry.rules[rule].map { (Node(rule.rawValue), Node($0 ? "on" : "off", .implicit, .plain)) }
            }
            if !rules.isEmpty {
                pairs.append((Node("rules"), Node.mapping(.init(rules, .implicit, .flow))))
            }
            return Node.mapping(.init(pairs))
        }

        return try ConfigurationV2Writer.render(key: "overrides", value: .sequence(.init(entries)))
    }

    private static func flowList(_ values: [String]) -> Node {
        .sequence(.init(values.map { Node($0) }, .implicit, .flow))
    }

    /// A setting value as a YAML node; nil is `null`.
    private static func node(of value: Any) throws -> Node {
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            guard let wrapped = mirror.children.first?.value else {
                return Node("null", .implicit, .plain)
            }

            return try node(of: wrapped)
        }

        return try Yams.compose(yaml: Yams.dump(object: value, width: -1, allowUnicode: true)) ?? Node("null", .implicit, .plain)
    }
}
