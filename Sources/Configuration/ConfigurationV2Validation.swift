import Foundation
import Shared
import SystemPackage
import Yams

/// The problems of a configuration file that declares `version: 2`, all reported together, each with its line.
public struct ConfigurationFileError: Error, LocalizedError, CustomStringConvertible {
    public let problems: [String]

    public var description: String {
        problems.joined(separator: "\n")
    }

    public var errorDescription: String? {
        description
    }
}

/// Checks a `version: 2` document against `ConfigurationV2`. Unknown keys, values of the wrong type and invalid enum
/// values are all collected, each located by its key path and line; the entries left decode into the model.
enum ConfigurationV2Validation {
    struct Problem {
        let mark: Mark?
        let message: String

        func formatted(file: FilePath) -> String {
            guard let mark else { return "\(file.string): \(message)" }

            return "\(file.string):\(mark.line):\(mark.column): \(message)"
        }
    }

    /// The model of the valid entries of the document, nil when none decodes, and the problems of the others.
    static func validate(_ root: Node) -> (model: ConfigurationV2?, problems: [Problem]) {
        let unknown = unknownKeys(in: root, prefix: [])
        var node = unknown.reduce(root) { removing($1.path[...], from: $0) ?? $0 }
        var problems = unknown.map { Problem(mark: $0.mark, message: $0.message) }

        while true {
            do {
                return (try YAMLDecoder().decode(ConfigurationV2.self, from: node), problems)
            } catch let error as DecodingError {
                let codingPath = error.codingPath
                problems.append(Problem(mark: mark(of: codingPath.map(Step.init), in: root), message: error.readableReason()))

                // The entry holding the value is dropped, so that the next decoding reports the next problem. In
                // `overrides`, only the entry of the override holding it.
                let isOverride = codingPath.first?.stringValue == "overrides"
                let entry = codingPath.enumerated()
                    .prefix { $0.element.intValue == nil || (isOverride && $0.offset == 1) }
                    .map { $0.element.intValue.map(String.init) ?? $0.element.stringValue }
                guard !entry.isEmpty, let pruned = removing(entry[...], from: node) else { return (nil, problems) }

                node = pruned
            } catch {
                problems.append(Problem(mark: nil, message: "\(error)"))
                return (nil, problems)
            }
        }
    }

    /// Where the value at a dotted path of the document is, e.g. `retain.public` or `overrides.0.modules`.
    static func mark(ofPath path: String, in root: Node) -> Mark? {
        mark(of: path.split(separator: ".").map { Int($0).map { .index($0) } ?? .key(String($0)) }, in: root)
    }

    /// A dotted path as messages show it, with the index of a list entry in brackets: `overrides[0].modules`.
    static func displayed(_ path: String) -> String {
        path.split(separator: ".").reduce(into: "") { result, component in
            if Int(component) != nil {
                result += "[\(component)]"
            } else {
                result += result.isEmpty ? String(component) : ".\(component)"
            }
        }
    }

    // MARK: - Private

    private enum Step {
        case key(String)
        case index(Int)

        init(_ key: CodingKey) {
            self = key.intValue.map { .index($0) } ?? .key(key.stringValue)
        }
    }

    /// The keys of a document, or of an entry of `overrides`, and the paths that hold other keys, e.g. `retain`.
    private struct Keys {
        let known: Set<String>
        let sections: Set<String>

        init(_ known: [String]) {
            self.known = Set(known)
            sections = Set(known.flatMap { path in
                let components = path.split(separator: ".")
                return (1 ..< max(1, components.count)).map { components.prefix($0).joined(separator: ".") }
            })
        }
    }

    private static let documentKeys = Keys(ConfigurationKeyMapping.all.map(\.v2Path) + ConfigurationKeyMapping.v2OnlyPaths)

    private static let overrideKeys = Keys(ConfigurationKeyMapping.overridePaths)

    /// The unknown keys under `node`, which sits at `prefix` in the document; the paths of `keys` start after the
    /// first `depth` components of `prefix`, `overrides.<index>` for an override.
    private static func unknownKeys(
        in node: Node,
        prefix: [String],
        keys: Keys = documentKeys,
        depth: Int = 0
    ) -> [(path: [String], mark: Mark?, message: String)] {
        guard case let .mapping(mapping) = node else { return [] }

        return mapping.flatMap { key, value -> [(path: [String], mark: Mark?, message: String)] in
            let path = prefix + [name(of: key)]
            let relative = path.dropFirst(depth).joined(separator: ".")

            if depth == 0, relative == "overrides", case let .sequence(entries) = value {
                // A value that is not a list is reported by the decoder.
                return entries.enumerated().flatMap { index, entry in
                    unknownKeys(in: entry, prefix: path + ["\(index)"], keys: overrideKeys, depth: 2)
                }
            }
            if keys.known.contains(relative) {
                return []
            }
            if keys.sections.contains(relative) {
                // A section that is not a mapping is reported by the decoder.
                return unknownKeys(in: value, prefix: path, keys: keys, depth: depth)
            }

            let suggestion = closestPath(to: path, keys: keys, depth: depth).map { " (did you mean '\(displayed($0))'?)" } ?? ""
            return [(path, key.mark, "unknown key '\(displayed(path.joined(separator: ".")))'\(suggestion)")]
        }
    }

    /// The path that an unknown key most likely stands for: the v2 path of a v1 key given at the top level, else the
    /// closest key of the same section.
    private static func closestPath(to path: [String], keys: Keys, depth: Int) -> String? {
        guard let key = path.last else { return nil }

        let normalized = key.lowercased().replacingOccurrences(of: "-", with: "_")
        let parent = path.dropFirst(depth).dropLast().joined(separator: ".")

        if depth == 0, parent.isEmpty, let mapping = ConfigurationKeyMapping.all.first(where: { $0.v1Key == normalized }) {
            return mapping.v2Path
        }

        let siblings = keys.known.union(keys.sections).compactMap { candidate -> String? in
            let components = candidate.split(separator: ".").map(String.init)
            guard components.dropLast().joined(separator: ".") == parent else { return nil }

            return components.last
        }

        // Rule ids are written with dashes, the other keys with underscores.
        let sectionNormalized = parent == "rules" ? key.lowercased().replacingOccurrences(of: "_", with: "-") : normalized

        return Configuration.closestKey(to: key, normalized: sectionNormalized, among: siblings)
            .map { (path.dropLast() + [$0]).joined(separator: ".") }
    }

    private static func mark(of steps: [Step], in root: Node) -> Mark? {
        var node = root

        for step in steps {
            guard let child = child(of: node, at: step) else { break }

            node = child
        }

        return node.mark
    }

    private static func child(of node: Node, at step: Step) -> Node? {
        switch (node, step) {
        case let (.mapping(mapping), .key(key)):
            mapping.first { name(of: $0.key) == key }?.value
        case let (.sequence(sequence), .index(index)):
            sequence.indices.contains(index) ? sequence[index] : nil
        case let (.mapping(mapping), .index(index)):
            mapping.first { name(of: $0.key) == "\(index)" }?.value
        default:
            nil
        }
    }

    /// The node without the entry at the path, nil when there is no such entry.
    private static func removing(_ path: ArraySlice<String>, from node: Node) -> Node? {
        if let key = path.first, let index = Int(key), case let .sequence(sequence) = node {
            guard sequence.indices.contains(index) else { return nil }

            var nodes = Array(sequence)
            if path.count > 1 {
                guard let pruned = removing(path.dropFirst(), from: nodes[index]) else { return nil }

                nodes[index] = pruned
            } else {
                nodes.remove(at: index)
            }

            return .sequence(Node.Sequence(nodes, sequence.tag, sequence.style, sequence.mark))
        }

        guard let key = path.first, case let .mapping(mapping) = node else { return nil }

        var found = false
        var pairs: [(Node, Node)] = []

        for (entryKey, value) in mapping {
            guard name(of: entryKey) == key else {
                pairs.append((entryKey, value))
                continue
            }

            found = true

            if path.count > 1 {
                guard let pruned = removing(path.dropFirst(), from: value) else { return nil }

                pairs.append((entryKey, pruned))
            }
        }

        return found ? .mapping(Node.Mapping(pairs, mapping.tag, mapping.style, mapping.mark)) : nil
    }

    private static func name(of key: Node) -> String {
        key.string ?? "\(key)"
    }
}

private extension DecodingError {
    var codingPath: [CodingKey] {
        switch self {
        case let .keyNotFound(key, context):
            context.codingPath + [key]
        case let .typeMismatch(_, context), let .valueNotFound(_, context), let .dataCorrupted(context):
            context.codingPath
        @unknown default:
            []
        }
    }
}
