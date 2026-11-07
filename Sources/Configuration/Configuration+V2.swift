import Foundation
import Shared
import SystemPackage

extension Configuration {
    /// The configuration file formats: 1 when the file has no `version`.
    static let supportedVersions = [1, 2]

    /// The format of a configuration file, from its `version` key.
    static func version(of document: [AnyHashable: Any], path: FilePath) throws -> Int {
        guard let value = document["version"] else { return 1 }
        guard let version = value as? Int, !(value is Bool), supportedVersions.contains(version) else {
            throw PeripheryError.usageError("\(path.string): unsupported 'version' \(SettingValueError.describe(value)), expected 1 or 2")
        }

        return version
    }

    /// Loads a file that declares `version: 2` into the settings, through `ConfigurationKeyMapping`. An unknown key and a
    /// value that does not decode are errors, reported together.
    func loadV2(yaml: String, document: [AnyHashable: Any], path: FilePath) throws {
        var problems = Self.unknownV2Keys(in: document)

        if problems.isEmpty {
            do {
                problems = apply(try ConfigurationV2(yaml: yaml))
            } catch let error as DecodingError {
                problems = [error.readableReason()]
            }
        }

        guard problems.isEmpty else {
            throw PeripheryError.usageError(problems.map { "\(path.string): \($0)" }.joined(separator: "\n"))
        }
    }

    // MARK: - Private

    private static let knownV2Paths = Set(ConfigurationKeyMapping.all.map(\.v2Path) + ConfigurationKeyMapping.v2OnlyPaths)

    /// The paths that hold other options, e.g. `retain`.
    private static let v2Sections = Set(knownV2Paths.flatMap { path in
        let components = path.split(separator: ".")
        return (1 ..< max(1, components.count)).map { components.prefix($0).joined(separator: ".") }
    })

    private static func unknownV2Keys(in mapping: [AnyHashable: Any], prefix: String = "") -> [String] {
        let entries = mapping.map { (key: "\($0.key.base)", value: $0.value) }.sorted { $0.key < $1.key }

        return entries.flatMap { key, value -> [String] in
            let path = prefix.isEmpty ? key : "\(prefix).\(key)"

            if knownV2Paths.contains(path) {
                return []
            }
            if v2Sections.contains(path) {
                // A section that is not a mapping is reported by the decoder.
                return (value as? [AnyHashable: Any]).map { unknownV2Keys(in: $0, prefix: path) } ?? []
            }

            return ["unknown key '\(path)'"]
        }
    }

    /// Assigns the values of the file to the settings, returns the problems.
    private func apply(_ model: ConfigurationV2) -> [String] {
        var problems: [String] = []
        var assigned: [String: (path: String, value: String)] = [:]

        for mapping in ConfigurationKeyMapping.all {
            guard let value = mapping.value?(model) else { continue }

            if let previous = assigned[mapping.v1Key] {
                if previous.value != "\(value)" {
                    problems.append("'\(previous.path)' and '\(mapping.v2Path)' must have the same value, they are not configurable separately yet")
                }
                continue
            }

            assigned[mapping.v1Key] = (mapping.v2Path, "\(value)")

            if let message = setting(withKey: mapping.v1Key).assign(value, reportedKey: mapping.v2Path) {
                problems.append(message)
            }
        }

        for rule in RuleIdentifier.allCases where rule.v1Key == nil {
            if let state = model.rules?[rule], state.isOn != rule.isEnabledByDefault {
                problems.append("'rules.\(rule.rawValue)' cannot be turned \(state.isOn ? "on" : "off"), the rule is always checked")
            }
        }

        if model.exclude?.indexDefaults == false {
            $indexExclude.isNormalizing = false
            indexExclude = model.exclude?.index ?? []
        }

        return problems
    }

    private func setting(withKey key: String) -> any AbstractSetting {
        guard let setting = settings.first(where: { $0.key == key }) else {
            preconditionFailure("ConfigurationKeyMapping names '\(key)', which is not a setting")
        }

        return setting
    }
}
