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

                // The entry holding the value is dropped, so that the next decoding reports the next problem.
                let entry = codingPath.prefix { $0.intValue == nil }.map(\.stringValue)
                guard !entry.isEmpty, let pruned = removing(entry[...], from: node) else { return (nil, problems) }

                node = pruned
            } catch {
                problems.append(Problem(mark: nil, message: "\(error)"))
                return (nil, problems)
            }
        }
    }

    /// Where the value at a dotted path of the document is, e.g. `retain.public`.
    static func mark(ofPath path: String, in root: Node) -> Mark? {
        mark(of: path.split(separator: ".").map { .key(String($0)) }, in: root)
    }

    // MARK: - Private

    private enum Step {
        case key(String)
        case index(Int)

        init(_ key: CodingKey) {
            self = key.intValue.map { .index($0) } ?? .key(key.stringValue)
        }
    }

    private static let knownPaths = Set(ConfigurationKeyMapping.all.map(\.v2Path) + ConfigurationKeyMapping.v2OnlyPaths)

    /// The paths that hold other options, e.g. `retain`.
    private static let sections = Set(knownPaths.flatMap { path in
        let components = path.split(separator: ".")
        return (1 ..< max(1, components.count)).map { components.prefix($0).joined(separator: ".") }
    })

    private static func unknownKeys(in node: Node, prefix: [String]) -> [(path: [String], mark: Mark?, message: String)] {
        guard case let .mapping(mapping) = node else { return [] }

        return mapping.flatMap { key, value -> [(path: [String], mark: Mark?, message: String)] in
            let path = prefix + [name(of: key)]
            let dotted = path.joined(separator: ".")

            if knownPaths.contains(dotted) {
                return []
            }
            if sections.contains(dotted) {
                // A section that is not a mapping is reported by the decoder.
                return unknownKeys(in: value, prefix: path)
            }

            let suggestion = closestPath(to: path).map { " (did you mean '\($0)'?)" } ?? ""
            return [(path, key.mark, "unknown key '\(dotted)'\(suggestion)")]
        }
    }

    /// The v2 path that an unknown key most likely stands for: the v2 path of a v1 key given at the top level, else the
    /// closest key of the same section.
    private static func closestPath(to path: [String]) -> String? {
        guard let key = path.last else { return nil }

        let normalized = key.lowercased().replacingOccurrences(of: "-", with: "_")
        let parent = path.dropLast().joined(separator: ".")

        if parent.isEmpty, let mapping = ConfigurationKeyMapping.all.first(where: { $0.v1Key == normalized }) {
            return mapping.v2Path
        }

        let siblings = knownPaths.union(sections).compactMap { candidate -> String? in
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
        default:
            nil
        }
    }

    /// The node without the entry at the path, nil when there is no such entry.
    private static func removing(_ path: ArraySlice<String>, from node: Node) -> Node? {
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
