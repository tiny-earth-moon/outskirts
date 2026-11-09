import Extensions
import Foundation
import Shared
import SystemPackage
import Yams

public extension Configuration {
    /// The configuration v2 equivalent of a v1 file, which loads into the same settings. The values are kept as
    /// written, `exclude.index_defaults` is left out as v1 always keeps the default globs, and the relative globs
    /// are rewritten from `projectRoot` to the directory of the file, which v2 resolves them from. Comments are kept:
    /// those above an option and at the end of its line move with it, those inside a value move above it, the header
    /// stays at the top, and the schema comment points to the v2 schema. A file that warns, or already declares
    /// `version: 2`, is an error.
    static func migratedToV2(file path: FilePath, projectRoot: FilePath = .current) throws -> String {
        let yaml = try String(contentsOf: path.url, encoding: .utf8)
        let mapping = try Yams.compose(yaml: yaml).map { node in
            guard let mapping = node.mapping else {
                throw PeripheryError.usageError("\(path.string): the configuration must be a mapping of keys to values")
            }

            return mapping
        }

        if let document = try Yams.load(yaml: yaml) as? [AnyHashable: Any], try version(of: document, path: path) == 2 {
            throw PeripheryError.usageError("\(path.string) already declares 'version: 2'")
        }

        var warnings: [String] = []
        let v1 = Configuration()
        try v1.load(from: path) { warnings.append($0) }
        guard warnings.isEmpty else {
            throw PeripheryError.usageError("Fix the configuration before migrating it:\n" + warnings.joined(separator: "\n"))
        }

        let directory = (path.isAbsolute ? path : projectRoot.pushing(path)).lexicallyNormalized().removingLastComponent()
        let rebase = ConfigurationMigration.globRebaser(from: projectRoot.lexicallyNormalized(), to: directory)
        let values = try ConfigurationMigration.v1Values(of: mapping, rebase: rebase)
        let entries = try ConfigurationV2Writer.entries(fromV1Values: values)
        var comments = ConfigurationMigration.comments(in: yaml, emittedKeys: Set(entries.flatMap(\.v1Keys)))
        comments.header.insert(v2SchemaComment, at: 0)
        let migrated = try ConfigurationV2Writer.render(entries, comments: comments)

        let v2 = Configuration()
        do {
            try v2.loadV2(yaml: migrated, path: path)
        } catch let error as ConfigurationFileError {
            throw PeripheryError.usageError("The migrated configuration does not load, please report it:\n" + error.problems.joined(separator: "\n"))
        }

        let differences = ConfigurationMigration.differences(v1: v1, anchoredTo: projectRoot, v2: v2)
        guard differences.isEmpty else {
            throw PeripheryError.usageError("The migrated configuration differs from \(path.string), please report it:\n" + differences.joined(separator: "\n"))
        }

        return migrated
    }
}

enum ConfigurationMigration {
    /// The v1 keys whose value holds globs relative to the project root.
    static let globKeys: Set = ["index_exclude", "report_exclude", "report_include", "retain_files", "localized_string_catalog_exclude"]

    /// The values of the v1 keys of a file, as written, read the way the v1 loader reads them: `retain_public` with a
    /// list is `retain_public_modules`. `index_exclude` is kept as written: v2 adds the default globs as v1 does.
    static func v1Values(of mapping: Node.Mapping?, rebase: @escaping (String) -> String) throws -> [String: Node] {
        var values: [String: Node] = [:]

        for (keyNode, value) in mapping ?? .init([]) {
            guard let key = keyNode.string, key != "version" else { continue }

            if key == "retain_public", value.sequence != nil {
                if values["retain_public_modules"] == nil {
                    values["retain_public_modules"] = value
                }
            } else if key == "retain_public_modules" {
                values[key] = value
            } else {
                values[key] = globKeys.contains(key) ? rebasing(value, with: rebase) : value
            }
        }

        return values
    }

    /// The settings that a v1 configuration and its migration set differently, the v1 globs anchored to `root` as v2
    /// anchors its globs to the directory of the file. `index_exclude` is compared as a set, and the platform
    /// conditional retention by the retention it resolves to.
    static func differences(v1: Configuration, anchoredTo root: FilePath, v2: Configuration) -> [String] {
        let anchor = { (glob: String) in Configuration.anchor(glob, to: root) }
        v1.indexExclude = v1.indexExclude.map(anchor)
        v1.reportInclude = v1.reportInclude.map(anchor)
        v1.retainFiles = v1.retainFiles.map(anchor)
        v1.localizedStringCatalogExclude = v1.localizedStringCatalogExclude.map(anchor)
        v1.reportExclude = v1.reportExclude.map { entry in
            switch entry {
            case let .pattern(glob): .pattern(anchor(glob))
            case let .scoped(path, kinds): .scoped(path: anchor(path), kinds: kinds)
            case .malformed: entry
            }
        }

        func effective(_ configuration: Configuration) -> [String: String] {
            Dictionary(uniqueKeysWithValues: configuration.settings.map { setting in
                if ["disable_platform_conditional_retention", "platform_conditional_retention"].contains(setting.key) {
                    return (setting.key, "\(configuration.resolvedPlatformConditionalRetention)")
                }
                if setting.key == "index_exclude", let globs = setting.wrappedValue as? [String] {
                    return (setting.key, "\(Set(globs).sorted())")
                }
                return (setting.key, "\(setting.wrappedValue)")
            })
        }

        let (lhs, rhs) = (effective(v1), effective(v2))
        return lhs.keys.sorted().filter { lhs[$0] != rhs[$0] }.map { "\($0): \(lhs[$0] ?? "") became \(rhs[$0] ?? "")" }
    }

    /// Rewrites a glob relative to `root` as relative to `directory`; a glob that starts with `/` or `*` is kept, as v2
    /// keeps it.
    static func globRebaser(from root: FilePath, to directory: FilePath) -> (String) -> String {
        guard root != directory else { return { $0 } }

        let rootComponents = Array(root.components)
        let directoryComponents = Array(directory.components)
        let common = zip(rootComponents, directoryComponents).prefix { $0 == $1 }.count
        let prefix = Array(repeating: "..", count: directoryComponents.count - common) + rootComponents[common...].map(\.string)

        return { glob in
            guard !glob.hasPrefix("/"), !glob.hasPrefix("*"), !prefix.isEmpty else { return glob }

            return (prefix + [glob]).joined(separator: "/")
        }
    }

    /// The comments of a v1 file, attached to the v1 key they document. Comments of a key that is not migrated, such as
    /// `disable_platform_conditional_retention: false`, go to the footer.
    static func comments(in yaml: String, emittedKeys: Set<String>) -> ConfigurationV2Writer.Comments {
        var comments = ConfigurationV2Writer.Comments()
        var pending: [String] = []
        var current: String?
        var inBlockScalar = false
        var orphans: [String] = []

        func attach(_ lines: [String], to key: String?) {
            guard let key else { return }

            comments.leading[key, default: []] += lines
        }

        for line in yaml.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }).map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                if inBlockScalar, line.first?.isWhitespace == true {
                    continue
                }
                if trimmed.hasPrefix("# yaml-language-server:") {
                    continue
                }
                pending.append(trimmed)
                continue
            }

            let isTopLevel = !(line.first?.isWhitespace ?? true)
            if inBlockScalar, !isTopLevel {
                continue
            }
            inBlockScalar = false

            let (content, inline) = splitInlineComment(line)
            if isTopLevel, let key = topLevelKey(content) {
                if current == nil {
                    // The comments before the first key are the header, but for those after its last blank line.
                    let split = pending.lastIndex(of: "").map { $0 + 1 } ?? pending.count
                    comments.header = trimmingBlankLines(Array(pending[..<split]))
                    pending = Array(pending[split...])
                }
                attach(trimmingBlankLines(pending), to: key)
                if let inline {
                    comments.inline[key] = inline
                }
                current = key
                pending = []
            } else {
                // A comment inside the value of the current key moves above it.
                attach(pending.filter { !$0.isEmpty } + (inline.map { [$0] } ?? []), to: current)
                pending = []
            }

            let value = content.trimmingCharacters(in: .whitespaces)
            inBlockScalar = value.range(of: #":\s*[|>][-+0-9]*$"#, options: .regularExpression) != nil
        }

        if current == nil {
            comments.header = trimmingBlankLines(pending)
        } else {
            comments.footer = trimmingBlankLines(pending)
        }

        for key in comments.leading.keys.sorted() where !emittedKeys.contains(key) {
            orphans += comments.leading.removeValue(forKey: key) ?? []
        }
        for key in comments.inline.keys.sorted() where !emittedKeys.contains(key) {
            orphans += comments.inline.removeValue(forKey: key).map { [$0] } ?? []
        }
        if !orphans.isEmpty {
            comments.footer = orphans + (comments.footer.isEmpty ? [] : [""] + comments.footer)
        }

        return comments
    }

    // MARK: - Private

    /// A glob value with its globs rebased: a glob (also `<glob>:kinds`), the `path` of a mapping, or a list of them.
    private static func rebasing(_ node: Node, with rebase: (String) -> String) -> Node {
        switch node {
        case let .scalar(scalar):
            var scalar = scalar
            scalar.string = rebase(scalar.string)
            return .scalar(scalar)
        case let .sequence(sequence):
            var sequence = sequence
            for index in sequence.indices {
                sequence[index] = rebasing(sequence[index], with: rebase)
            }
            return .sequence(sequence)
        case var .mapping(mapping):
            if let path = mapping["path"] {
                mapping["path"] = rebasing(path, with: rebase)
            }
            return .mapping(mapping)
        case .alias:
            return node
        }
    }

    /// The key of a line that starts a top-level option, `key: value` or `key:`.
    private static func topLevelKey(_ line: String) -> String? {
        guard !line.hasPrefix("-"), !line.hasPrefix("{"), !line.hasPrefix("["), !line.hasPrefix("---"),
              let colon = line.firstIndex(of: ":")
        else { return nil }

        let key = line[..<colon].trimmingCharacters(in: .whitespaces)
        return key.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }

    /// The line without its trailing comment, and the comment: a `#` after a blank, outside quotes.
    private static func splitInlineComment(_ line: String) -> (content: String, comment: String?) {
        var quote: Character?
        var previous: Character = " "

        for index in line.indices {
            let character = line[index]
            if let open = quote {
                if character == open, !(open == "\"" && previous == "\\") {
                    quote = nil
                }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "#", previous.isWhitespace {
                return (String(line[..<index]), String(line[index...]))
            }
            previous = character
        }

        return (line, nil)
    }

    private static func trimmingBlankLines(_ lines: [String]) -> [String] {
        Array(lines.drop { $0.isEmpty }.reversed().drop { $0.isEmpty }.reversed())
    }
}
