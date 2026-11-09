import Foundation
import Shared
import SystemPackage
import Yams

public extension Configuration {
    func asYaml() throws -> String {
        var config: [String: Any?] = [:]

        for setting in settings where setting.hasNonDefaultValue {
            config[setting.key] = setting.wrappedValue
        }

        return try Yams.dump(object: config)
    }

    /// Writes the configuration file atomically. With a `root`, the file is written at its real path, which must stay
    /// inside `root`; without one, never over a symbolic link (see `OutputFile`).
    func save(to path: FilePath = defaultConfigurationFile, within root: FilePath? = nil) throws {
        let data = try Data((Self.schemaComment + "\n" + asYaml()).utf8)
        if let root {
            try OutputFile.writeConfined(data, to: path, within: root)
        } else {
            try OutputFile.write(data, to: path)
        }
    }

    /// Loads the configuration file. A file with `version: 2` loads through `ConfigurationV2`, where any problem is an
    /// error, all of them thrown together as a `ConfigurationFileError`. Otherwise, a value that is not valid for its setting, and a key that is not a setting, are reported to
    /// `warn` and ignored, an unreadable file or a document that is not a mapping is an error.
    func load(from path: FilePath?, warn: (String) -> Void) throws {
        guard let path = try configurationPath(withUserProvided: path) else { return }

        let encodedYAML = try String(contentsOf: path.url, encoding: .utf8)
        loadedFiles = [path]

        // An empty document is an empty configuration.
        guard let document = try Yams.load(yaml: encodedYAML) else { return }
        guard let yaml = document as? [AnyHashable: Any] else {
            throw PeripheryError.usageError("\(path.string): the configuration must be a mapping of keys to values, got \(SettingValueError.describe(document))")
        }

        if try Self.version(of: yaml, path: path) == 2 {
            try loadV2(yaml: encodedYAML, path: path)
            return
        }

        let entries = yaml
            .filter { $0.key.base as? String != "version" }
            .map { (key: "\($0.key.base)", value: $0.value, isString: $0.key.base is String) }
            .sorted { $0.key < $1.key }

        if let key = entries.map(\.key).first(where: Self.isRemovedBazelKey) {
            throw PeripheryError.removedBazelOption("'\(key)' in \(path.string)")
        }

        for (key, value, isString) in entries {
            if isString, key == $retainPublic.key, value is [Any] {
                if let message = $retainPublicModules.assign(value, reportedKey: key) {
                    warn("\(path.string): \(message)")
                }
            } else if isString, let setting = settings.first(where: { key == $0.key }) {
                if let message = setting.assign(value) {
                    warn("\(path.string): \(message)")
                }
            } else if isString, let suggestion = closestSettingKey(to: key) {
                warn("\(path.string): invalid key '\(key)' (did you mean '\(suggestion)'?)")
            } else {
                warn("\(path.string): invalid key '\(key)'")
            }
        }
    }

    /// The configuration file to read: the given one, which must exist, or else the first existing default file.
    func configurationPath(withUserProvided path: FilePath?) throws -> FilePath? {
        if let path {
            if !path.exists {
                throw PeripheryError.pathDoesNotExist(path: path.lexicallyNormalized().string)
            }

            return path
        }

        return Self.configurationFileNames.map { FilePath($0) }.first { $0.exists }
    }

    // MARK: - Private

    /// The setting key that a misspelt key most likely stands for, if any is close enough.
    private func closestSettingKey(to key: String) -> String? {
        Self.closestKey(to: key, normalized: key.lowercased().replacingOccurrences(of: "-", with: "_"), among: settings.map(\.key))
    }

    /// The candidate that a misspelt key most likely stands for: the one equal to its normalized form, else the
    /// closest one within a few edits.
    internal static func closestKey(to key: String, normalized: String, among candidates: [String]) -> String? {
        let candidates = candidates.sorted()

        if let exact = candidates.first(where: { $0 == normalized }) {
            return exact
        }

        let maxDistance = min(3, max(1, key.count / 4))
        let ranked = candidates.map { (key: $0, distance: editDistance(normalized, $0)) }

        return ranked.filter { $0.distance <= maxDistance }.min { $0.distance < $1.distance }?.key
    }

    /// The Levenshtein distance between two strings.
    private static func editDistance(_ lhs: String, _ rhs: String) -> Int {
        let lhs = Array(lhs)
        let rhs = Array(rhs)
        var previous = Array(0 ... rhs.count)

        for (i, l) in lhs.enumerated() {
            var current = [i + 1]

            for (j, r) in rhs.enumerated() {
                current.append(min(previous[j + 1] + 1, current[j] + 1, previous[j] + (l == r ? 0 : 1)))
            }

            previous = current
        }

        return previous[rhs.count]
    }

    /// Keys of the Bazel mode, removed in 3.13.0, which are rejected instead of being reported as invalid keys.
    /// - Note: Deprecated: this shim is a thin check in front of the generic unknown key handling and goes away with it.
    private static func isRemovedBazelKey(_ key: String) -> Bool {
        key == "bazel" || key.hasPrefix("bazel_")
    }
}

// MARK: - Yaml Encoding

extension OutputFormat: Yams.ScalarRepresentable {
    public func represented() -> Node.Scalar {
        rawValue.represented()
    }
}

extension FilePath: Yams.ScalarRepresentable {
    public func represented() -> Node.Scalar {
        string.represented()
    }
}

extension ColorOption: Yams.ScalarRepresentable {
    public func represented() -> Node.Scalar {
        rawValue.represented()
    }
}

extension PlatformConditionalRetention: Yams.ScalarRepresentable {
    public func represented() -> Node.Scalar {
        rawValue.represented()
    }
}

extension ExitCodes: Yams.ScalarRepresentable {
    public func represented() -> Node.Scalar {
        rawValue.represented()
    }
}

public extension Configuration {
    /// Whether the error comes from a configuration file that is not valid YAML.
    static func isMalformedFileError(_ error: Error) -> Bool {
        error is YamlError
    }
}
