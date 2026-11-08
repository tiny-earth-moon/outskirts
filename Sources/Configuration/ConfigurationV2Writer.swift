import Foundation
import Shared
import Yams

/// Writes a configuration v2 file from values of v1 keys, as `config migrate` and `config print` do: the sections in a
/// fixed order, the options of a section in the order of `ConfigurationKeyMapping`, so that the output is stable.
enum ConfigurationV2Writer {
    /// A v2 option ready to be written, with the v1 keys it comes from.
    struct Entry {
        let path: String
        let value: Node
        let v1Keys: [String]
    }

    /// The comments to keep around the options.
    struct Comments {
        var header: [String] = []
        var footer: [String] = []
        /// The comment lines written above the option of each v1 key.
        var leading: [String: [String]] = [:]
        /// The comment written at the end of the line of each v1 key.
        var inline: [String: String] = [:]
    }

    /// The order of the sections of a v2 file; `variants` is a top-level option.
    static let sectionOrder = ["project", "build", "variants", "exclude", "rules", "retain", "analysis", "report", "baseline"]

    /// Every v2 path a v1 key drives, plus `exclude.index_defaults`, in the order they are written.
    static let orderedPaths: [String] = {
        var paths: [String] = []
        for path in ConfigurationKeyMapping.all.map(\.v2Path) where !paths.contains(path) {
            paths.append(path)
            if path == "exclude.index" {
                paths.append("exclude.index_defaults")
            }
        }
        return paths.sorted { lhs, rhs in
            let lhsSection = sectionOrder.firstIndex(of: section(of: lhs)) ?? .max
            let rhsSection = sectionOrder.firstIndex(of: section(of: rhs)) ?? .max
            if lhsSection != rhsSection {
                return lhsSection < rhsSection
            }
            return paths.firstIndex(of: lhs)! < paths.firstIndex(of: rhs)!
        }
    }()

    /// The v2 options set by the given values of v1 keys, in the order they are written. A key left out keeps its
    /// default. `index_exclude` is written with `index_defaults: false`, the default globs being in the list.
    static func entries(fromV1Values values: [String: Node]) throws -> [Entry] {
        var entries: [Entry] = []

        for path in orderedPaths {
            if let entry = try entry(at: path, values: values) {
                entries.append(entry)
            }
        }

        return entries
    }

    /// The YAML of a v2 file holding the entries, then `trailing` (top-level YAML such as `overrides`).
    static func render(_ entries: [Entry], comments: Comments = .init(), trailing: [String] = []) throws -> String {
        var lines = comments.header
        lines.append("version: 2")

        var currentSection: String?
        for entry in entries {
            let section = section(of: entry.path)
            let isTopLevel = !entry.path.contains(".")
            let indent = isTopLevel ? "" : "  "

            if !isTopLevel, section != currentSection {
                lines.append("\(section):")
            }
            currentSection = isTopLevel ? nil : section

            let leading = entry.v1Keys.flatMap { comments.leading[$0] ?? [] }
            lines += leading.map { $0.isEmpty ? "" : indent + $0 }

            var rendered = try render(key: leaf(of: entry.path), value: entry.value)
            let inline = entry.v1Keys.compactMap { comments.inline[$0] }
            if !inline.isEmpty {
                if rendered.count == 1 {
                    rendered[0] += "  " + inline.joined(separator: " ")
                } else {
                    rendered.insert(contentsOf: inline, at: 0)
                }
            }
            lines += rendered.map { indent + $0 }
        }

        lines += trailing

        if !comments.footer.isEmpty {
            lines.append("")
            lines += comments.footer
        }

        return lines.joined(separator: "\n") + "\n"
    }

    /// The lines of `key: value`, a list or a mapping value continuing on the next lines.
    static func render(key: String, value: Node) throws -> [String] {
        let yaml = try Yams.serialize(node: Node.mapping(.init([(Node(key), value)])), width: -1, allowUnicode: true)
        return yaml.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).dropLast(yaml.hasSuffix("\n") ? 1 : 0)
    }

    // MARK: - Private

    private static func section(of path: String) -> String {
        String(path.split(separator: ".").first ?? "")
    }

    private static func leaf(of path: String) -> String {
        String(path.split(separator: ".").last ?? "")
    }

    private static func entry(at path: String, values: [String: Node]) throws -> Entry? {
        func bool(_ key: String) throws -> Bool? {
            guard let node = values[key] else { return nil }
            guard let value = node.bool else {
                throw PeripheryError.usageError("'\(key)' expects a boolean")
            }

            return value
        }

        if path.hasPrefix("rules.") {
            guard let rule = RuleIdentifier(rawValue: String(path.dropFirst("rules.".count))),
                  let key = rule.v1Key, let value = try bool(key)
            else { return nil }

            return Entry(path: path, value: plain(value == rule.v1Value(enabled: true) ? "on" : "off"), v1Keys: [key])
        }

        switch path {
        case "exclude.index_defaults":
            guard values["index_exclude"] != nil else { return nil }

            return Entry(path: path, value: plain("false"), v1Keys: [])
        case "retain.objc":
            let keys = ["retain_objc_annotated", "retain_objc_accessible"]
            guard keys.contains(where: { values[$0] != nil }) else { return nil }

            var modes: [String] = []
            if try bool("retain_objc_annotated") == true {
                modes.append("annotated")
            }
            if try bool("retain_objc_accessible") == true {
                modes.append("accessible")
            }
            let value: Node = switch modes.count {
            case 0: plain("off")
            case 1: plain(modes[0])
            default: flowList(modes)
            }
            return Entry(path: path, value: value, v1Keys: keys)
        case "retain.properties_of":
            let protocols = [
                ("retain_codable_properties", "Codable"), ("retain_encodable_properties", "Encodable"),
                ("retain_equatable_properties", "Equatable"), ("retain_hashable_properties", "Hashable"),
            ]
            guard protocols.contains(where: { values[$0.0] != nil }) else { return nil }

            let retained = try protocols.filter { try bool($0.0) == true }.map(\.1)
            return Entry(path: path, value: flowList(retained), v1Keys: protocols.map(\.0))
        case "retain.platform_conditional":
            let keys = ["platform_conditional_retention", "disable_platform_conditional_retention"]
            if try bool("disable_platform_conditional_retention") == true {
                return Entry(path: path, value: plain("off"), v1Keys: keys)
            }
            guard let value = values["platform_conditional_retention"] else { return nil }

            return Entry(path: path, value: value, v1Keys: keys)
        case "report.update_check":
            guard let value = try bool("disable_update_check") else { return nil }

            return Entry(path: path, value: plain(value ? "false" : "true"), v1Keys: ["disable_update_check"])
        default:
            guard let key = ConfigurationKeyMapping.all.first(where: { $0.v2Path == path })?.v1Key,
                  let value = values[key]
            else { return nil }

            // v1 reads a scalar as a one-element list, v2 does not.
            if listKeys.contains(key), case .scalar = value {
                return Entry(path: path, value: .sequence(.init([value])), v1Keys: [key])
            }
            return Entry(path: path, value: value, v1Keys: [key])
        }
    }

    /// The v1 keys whose value is a list, which v1 also accepts as a single scalar.
    private static let listKeys: Set<String> = Set(Configuration().settings.filter { [.stringList, .pathList].contains($0.kind) }.map(\.key))

    private static func plain(_ value: String) -> Node {
        Node(value, .implicit, .plain)
    }

    private static func flowList(_ values: [String]) -> Node {
        Node.sequence(.init(values.map { plain($0) }, .implicit, .flow))
    }
}
