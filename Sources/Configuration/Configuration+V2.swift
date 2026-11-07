import Foundation
import Shared
import SystemPackage
import Yams

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

    /// Loads a file that declares `version: 2` into the settings, through `ConfigurationKeyMapping`. An unknown key, a
    /// value of the wrong type, an invalid enum value and a value a setting rejects are errors, all reported together
    /// with their line by a `ConfigurationFileError`.
    func loadV2(yaml: String, path: FilePath) throws {
        guard let root = try Yams.compose(yaml: yaml) else { return }

        let validation = ConfigurationV2Validation.validate(root)
        var problems = validation.problems

        if let model = validation.model {
            problems += apply(model).map { path, message in
                ConfigurationV2Validation.Problem(mark: ConfigurationV2Validation.mark(ofPath: path, in: root), message: message)
            }
        }

        guard problems.isEmpty else {
            let ordered = problems.enumerated().sorted { lhs, rhs in
                (lhs.element.mark?.line ?? .max, lhs.element.mark?.column ?? .max, lhs.offset) <
                    (rhs.element.mark?.line ?? .max, rhs.element.mark?.column ?? .max, rhs.offset)
            }

            throw ConfigurationFileError(problems: ordered.map { $0.element.formatted(file: path) })
        }
    }

    // MARK: - Private

    /// Assigns the values of the file to the settings, returns the problems with the path they concern.
    private func apply(_ model: ConfigurationV2) -> [(path: String, message: String)] {
        var problems: [(path: String, message: String)] = []
        var assigned: [String: (path: String, value: String)] = [:]

        for mapping in ConfigurationKeyMapping.all {
            guard let value = mapping.value?(model) else { continue }

            if let previous = assigned[mapping.v1Key] {
                if previous.value != "\(value)" {
                    problems.append((mapping.v2Path, "'\(previous.path)' and '\(mapping.v2Path)' must have the same value, they are not configurable separately yet"))
                }
                continue
            }

            assigned[mapping.v1Key] = (mapping.v2Path, "\(value)")

            if let message = setting(withKey: mapping.v1Key).assign(value, reportedKey: mapping.v2Path) {
                problems.append((mapping.v2Path, message))
            }
        }

        for rule in RuleIdentifier.allCases where rule.v1Key == nil {
            if let state = model.rules?[rule], state.isOn != rule.isEnabledByDefault {
                problems.append(("rules.\(rule.rawValue)", "'rules.\(rule.rawValue)' cannot be turned \(state.isOn ? "on" : "off"), the rule is always checked"))
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
