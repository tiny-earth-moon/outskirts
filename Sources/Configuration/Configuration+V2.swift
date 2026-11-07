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

    /// Loads a file that declares `version: 2`, after the files it extends, into the settings, through
    /// `ConfigurationKeyMapping`. Each file overrides the values of the files it extends, and its paths and globs are
    /// relative to its directory. An unknown key, a value of the wrong type, an invalid enum value, a value a setting
    /// rejects and an `extends` cycle are errors, all reported together, each with its file and line, by a
    /// `ConfigurationFileError`.
    func loadV2(yaml: String, path: FilePath) throws {
        var files: [V2File] = []
        try collectV2Files(yaml: yaml, path: path, chain: [], into: &files)

        let problems = files.flatMap { file in
            let applied = file.model.map { apply($0.anchoringGlobs(to: file.directory)) } ?? []
            let problems = file.problems + applied.map { path, message in
                ConfigurationV2Validation.Problem(mark: ConfigurationV2Validation.mark(ofPath: path, in: file.root), message: message)
            }

            return Self.formatted(problems, file: file.path)
        }

        guard problems.isEmpty else {
            throw ConfigurationFileError(problems: problems)
        }
    }

    /// A glob of a file in `directory` made absolute. A glob that starts with `/` or `*` is kept as written.
    static func anchor(_ glob: String, to directory: FilePath) -> String {
        guard !glob.hasPrefix("/"), !glob.hasPrefix("*") else { return glob }

        return directory.pushing(FilePath(glob)).lexicallyNormalized().string
    }

    // MARK: - Private

    /// A `version: 2` file read by `loadV2`.
    private struct V2File {
        let path: FilePath
        /// The absolute directory of the file, which its relative paths start from.
        let directory: FilePath
        let root: Node
        let model: ConfigurationV2?
        /// The problems found reading the file, before its values are applied.
        let problems: [ConfigurationV2Validation.Problem]
    }

    /// Reads a file and, before it, the files it extends, recursively; `chain` holds the files that extend it.
    private func collectV2Files(
        yaml: String,
        path: FilePath,
        chain: [FilePath],
        into files: inout [V2File]
    ) throws {
        guard let root = try Yams.compose(yaml: yaml) else { return }

        let validation = ConfigurationV2Validation.validate(root)
        let absolutePath = (path.isAbsolute ? path : FilePath.current.pushing(path)).lexicallyNormalized()
        let directory = absolutePath.removingLastComponent()
        let extending = chain + [absolutePath]
        var fileProblems = validation.problems

        for (index, base) in (validation.model?.extends?.paths ?? []).enumerated() {
            let basePath = directory.pushing(FilePath(base)).lexicallyNormalized()

            do {
                if let cycleStart = extending.firstIndex(of: basePath) {
                    let cycle = extending[cycleStart...] + [basePath]
                    throw PeripheryError.usageError("'extends' forms a cycle: \(cycle.map(\.string).joined(separator: " -> "))")
                }
                guard basePath.exists else {
                    throw PeripheryError.usageError("'extends' names '\(base)', which does not exist")
                }

                let baseYAML = try String(contentsOf: basePath.url, encoding: .utf8)
                guard let document = try Yams.load(yaml: baseYAML) as? [AnyHashable: Any],
                      try Self.version(of: document, path: basePath) == 2
                else {
                    throw PeripheryError.usageError("'extends' names '\(base)', which is not a configuration file with 'version: 2'")
                }

                try collectV2Files(yaml: baseYAML, path: basePath, chain: extending, into: &files)
            } catch {
                let mark = ConfigurationV2Validation.mark(ofPath: "extends.\(index)", in: root)
                fileProblems.append(ConfigurationV2Validation.Problem(mark: mark, message: Self.message(of: error)))
            }
        }

        files.append(V2File(path: path, directory: directory, root: root, model: validation.model, problems: fileProblems))
    }

    private static func message(of error: Error) -> String {
        if let error = error as? PeripheryError, case let .usageError(message) = error {
            return message
        }

        return "\(error)"
    }

    /// The problems of a file in line order, each prefixed with the file.
    private static func formatted(_ problems: [ConfigurationV2Validation.Problem], file: FilePath) -> [String] {
        problems.enumerated()
            .sorted { lhs, rhs in
                (lhs.element.mark?.line ?? .max, lhs.element.mark?.column ?? .max, lhs.offset) <
                    (rhs.element.mark?.line ?? .max, rhs.element.mark?.column ?? .max, rhs.offset)
            }
            .map { $0.element.formatted(file: file) }
    }

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

        // A file that does not set `index_defaults` keeps the choice of the file it extends.
        if let keepsDefaults = model.exclude?.indexDefaults, keepsDefaults != $indexExclude.isNormalizing {
            let defaults = $indexExclude.defaultValue
            let globs = model.exclude?.index ?? indexExclude.filter { !defaults.contains($0) }
            $indexExclude.isNormalizing = keepsDefaults
            indexExclude = globs
        }

        for (index, entry) in (model.overrides ?? []).enumerated() {
            problems += applyOverride(entry, at: "overrides.\(index)")
        }

        return problems
    }

    /// Appends an entry of `overrides`, returns its problems.
    private func applyOverride(_ entry: OverrideV2, at path: String) -> [(path: String, message: String)] {
        var problems: [(path: String, message: String)] = []
        let displayedPath = ConfigurationV2Validation.displayed(path)

        if (entry.modules ?? []).isEmpty, (entry.paths ?? []).isEmpty {
            problems.append((path, "'\(displayedPath)' must match 'modules' or 'paths'"))
        }

        for (rule, state) in entry.rules ?? [:] {
            let rulePath = "\(path).rules.\(rule.rawValue)"
            let displayedRule = ConfigurationV2Validation.displayed(rulePath)

            if !ConfigurationOverride.overridableRules.contains(rule) {
                let supported = ConfigurationOverride.overridableRules.map(\.rawValue).sorted().joined(separator: ", ")
                problems.append((rulePath, "'\(displayedRule)' cannot be set in an override, only: \(supported)"))
            } else if state.isOn, !isEnabled(rule) {
                problems.append((rulePath, "'\(displayedRule)' cannot turn on a rule that is off at the top level, turn it on there and off in the overrides"))
            }
        }

        overrides.append(ConfigurationOverride(
            modules: entry.modules ?? [],
            paths: entry.paths ?? [],
            retainPublic: entry.retain?.publicDeclarations,
            retainAll: entry.retain?.all,
            rules: (entry.rules ?? [:]).mapValues(\.isOn)
        ))

        return problems
    }

    private func setting(withKey key: String) -> any AbstractSetting {
        guard let setting = settings.first(where: { $0.key == key }) else {
            preconditionFailure("ConfigurationKeyMapping names '\(key)', which is not a setting")
        }

        return setting
    }
}

extension ConfigurationV2 {
    /// The file with its relative globs made absolute from its directory: `exclude.index`, `exclude.report`,
    /// `exclude.localized_string_catalogs`, `report.include`, `retain.files` and the `paths` of `overrides`.
    func anchoringGlobs(to directory: FilePath) -> Self {
        let anchor = { (glob: String) in Configuration.anchor(glob, to: directory) }
        var model = self

        model.exclude?.index = exclude?.index?.map(anchor)
        model.exclude?.report = exclude?.report?.anchoringReportExcludeGlobs(with: anchor)
        model.exclude?.localizedStringCatalogs = exclude?.localizedStringCatalogs?.map(anchor)
        model.report?.include = report?.include?.map(anchor)
        model.retain?.files = retain?.files?.map(anchor)
        model.overrides = overrides?.map { entry in
            var entry = entry
            entry.paths = entry.paths?.map(anchor)
            return entry
        }

        return model
    }
}

private extension YAMLValue {
    /// The `exclude.report` value with its globs anchored: a glob (also as `<glob>:kinds`), the `path` of an object, or
    /// a list of them.
    func anchoringReportExcludeGlobs(with anchor: (String) -> String) -> Self {
        switch self {
        case let .scalar(glob):
            return .scalar(anchor(glob))
        case let .list(values):
            return .list(values.map { $0.anchoringReportExcludeGlobs(with: anchor) })
        case var .mapping(values):
            if case let .scalar(path) = values["path"] {
                values["path"] = .scalar(anchor(path))
            }
            return .mapping(values)
        }
    }
}
