import Foundation
import Logger
import SourceGraph
import SystemPackage
import XcodeProj

public final class XcodeTarget {
    let project: XcodeProject

    private let target: PBXTarget
    private let logger: Logger
    private var files: [ProjectFileKind: Set<FilePath>] = [:]
    public private(set) var swiftSourceFiles: Set<FilePath> = []

    required init(project: XcodeProject, target: PBXTarget, logger: Logger) {
        self.project = project
        self.target = target
        self.logger = logger
    }

    public var isTestTarget: Bool {
        target.productType?.rawValue.contains("test") ?? false
    }

    public var name: String {
        target.name
    }

    public func identifyFiles() throws {
        let groupFiles = try synchronizedGroupFiles()
        try identifyFiles(in: groupFiles)
        swiftSourceFiles = groupFiles.filter { $0.extension?.lowercased() == "swift" }

        let sourcesBuildPhases = project.xcodeProject.pbxproj.sourcesBuildPhases
        let resourcesBuildPhases = project.xcodeProject.pbxproj.resourcesBuildPhases

        swiftSourceFiles.formUnion(try swiftFiles(in: sourcesBuildPhases))
        try identifyFiles(kind: .xcDataModel, in: sourcesBuildPhases)
        try identifyFiles(kind: .xcMappingModel, in: sourcesBuildPhases)
        try identifyFiles(kind: .interfaceBuilder, in: resourcesBuildPhases)
        try identifyFiles(kind: .xcStrings, in: resourcesBuildPhases)
        try identifyInfoPlistFiles()
        files = files.mapValues { existingFiles(in: $0) { logger.warn($0) } }
    }

    /// Drops the files referenced by the project that do not exist on disk, such as the Info.plist of a configuration
    /// that is never built or a file Xcode shows in red, with a warning instead of failing the scan.
    func existingFiles(in paths: Set<FilePath>, warn: (String) -> Void) -> Set<FilePath> {
        paths.filter { path in
            guard path.exists else {
                warn("File '\(path.string)' of target '\(target.name)' does not exist, not analyzed.")
                return false
            }

            return true
        }
    }

    /// Values of the `ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME` build setting in the target configurations.
    public var globalAccentColorNames: Set<String> {
        let settings = target.buildConfigurationList?.buildConfigurations.map(\.buildSettings) ?? []

        return settings.flatMapSet { buildSettings -> Set<String> in
            switch buildSettings["ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME"] {
            case let .string(value): [value]
            case let .array(values): Set(values)
            case nil: []
            }
        }
    }

    /// The SDK names of the platforms the target supports in its configurations: `SUPPORTED_PLATFORMS`, else
    /// `SDKROOT`, of the target settings, else of the project ones. Empty when an `.xcconfig` file sets them.
    public var supportedSDKs: Set<String> {
        let configurations = target.buildConfigurationList?.buildConfigurations ?? []

        return configurations.flatMapSet { configuration -> Set<String> in
            let levels = [configuration.buildSettings, projectConfiguration(named: configuration.name)?.buildSettings ?? [:]]
            let value = levels.lazy.compactMap { $0["SUPPORTED_PLATFORMS"] ?? $0["SDKROOT"] }.first
            let names: [String] = switch value {
            case let .string(string): string.split(separator: " ").map(String.init)
            case let .array(values): values
            case nil: []
            }
            return Set(names.filter { !$0.contains("$") })
        }
    }

    /// The name of the module the target compiles: `PRODUCT_MODULE_NAME`, else `PRODUCT_NAME`, else the target
    /// name, made a C identifier. `nil` when the configurations disagree, or a setting refers to a variable other than
    /// `TARGET_NAME` (e.g. one set in an `.xcconfig` file).
    public var moduleName: String? {
        let configurations = target.buildConfigurationList?.buildConfigurations ?? []
        let names = configurations.map { configuration -> String? in
            let settings = buildSettings(of: configuration)
            var value = settings["PRODUCT_MODULE_NAME"] ?? settings["PRODUCT_NAME"] ?? "$(TARGET_NAME)"
            for reference in ["$(TARGET_NAME)", "${TARGET_NAME}", "$(TARGET_NAME:c99extidentifier)", "${TARGET_NAME:c99extidentifier}"] {
                value = value.replacingOccurrences(of: reference, with: target.name)
            }
            return value.contains("$") || value.isEmpty ? nil : Self.c99Identifier(value)
        }

        guard let name = names.first ?? Self.c99Identifier(target.name), names.allSatisfy({ $0 == name }) else { return nil }

        return name
    }

    static func c99Identifier(_ value: String) -> String {
        let identifier = String(value.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") ? $0 : "_" })

        return identifier.first?.isNumber == true ? "_" + identifier : identifier
    }

    public func files(kind: ProjectFileKind) -> Set<FilePath> {
        files[kind, default: []]
    }

    // MARK: - Private

    /// Files of the file system synchronized groups (Xcode 16+) belonging to this target, minus the files the
    /// target is excluded from via `membershipExceptions`.
    private func synchronizedGroupFiles() throws -> Set<FilePath> {
        let sourceRoot = project.sourceRoot.lexicallyNormalized()

        return try (target.fileSystemSynchronizedGroups ?? []).flatMapSet { group in
            guard let stringPath = try group.fullPath(sourceRoot: sourceRoot.string) else { return [] }

            let groupPath = FilePath(stringPath).lexicallyNormalized()
            let exceptions = (group.exceptions ?? [])
                .compactMap { $0 as? PBXFileSystemSynchronizedBuildFileExceptionSet }
                .filter { $0.target === target }
                .flatMap { $0.membershipExceptions ?? [] }
            let excludedPaths = exceptions.mapSet { groupPath.appending($0).lexicallyNormalized() }

            return FilePath.glob(groupPath.appending("**/*").string, onUnreadableDirectory: logger.warnUnreadableDirectory).filter { path in
                !excludedPaths.contains { path == $0 || path.starts(with: $0) }
            }
        }
    }

    private func swiftFiles(in buildPhases: [PBXBuildPhase]) throws -> Set<FilePath> {
        let sourceRoot = project.sourceRoot.lexicallyNormalized()

        return try buildPhases.filter { target.buildPhases.contains($0) }.flatMapSet {
            try ($0.files ?? []).compactMapSet {
                guard let stringPath = try $0.file?.fullPath(sourceRoot: sourceRoot.string) else { return nil }

                let path = FilePath(stringPath).lexicallyNormalized()
                return path.extension?.lowercased() == "swift" ? path : nil
            }
        }
    }

    private func identifyFiles(kind: ProjectFileKind, in buildPhases: [PBXBuildPhase]) throws {
        let targetPhases = buildPhases.filter { target.buildPhases.contains($0) }
        let sourceRoot = project.sourceRoot.lexicallyNormalized()

        let foundFiles = try targetPhases.flatMapSet {
            try ($0.files ?? []).compactMapSet {
                if let stringPath = try $0.file?.fullPath(sourceRoot: sourceRoot.string) {
                    let path = FilePath(stringPath)
                    if let ext = path.extension, kind.extensions.contains(ext.lowercased()) {
                        return path
                    }
                }

                return nil
            }
        }
        files[kind, default: []].formUnion(foundFiles)
    }

    private func identifyFiles(in paths: Set<FilePath>) throws {
        // Info.plist files are located exclusively through the INFOPLIST_FILE build setting.
        let kinds = ProjectFileKind.allCases.filter { $0 != .infoPlist }

        for path in paths {
            for kind in kinds {
                if let ext = path.extension, kind.extensions.contains(ext.lowercased()) {
                    files[kind, default: []].insert(path)
                }
            }
        }
    }

    private func identifyInfoPlistFiles() throws {
        let configurations = target.buildConfigurationList?.buildConfigurations ?? []
        var paths: Set<FilePath> = []

        for configuration in configurations {
            let settings: [String] = switch configuration.buildSettings["INFOPLIST_FILE"] {
            case let .string(value): [value]
            case let .array(values): values
            case nil: []
            }

            for setting in settings {
                if let path = resolveInfoPlistSetting(setting, buildSettings: buildSettings(of: configuration), warn: { logger.warn($0) }) {
                    paths.insert(path)
                }
            }
        }

        files[.infoPlist] = paths
    }

    /// The path of an `INFOPLIST_FILE` setting, with its `$(VAR)` / `${VAR}` references expanded from the target and
    /// project build settings of the configuration, relative to the source root unless absolute. A variable that
    /// cannot be expanded from the project file (e.g. set in an `.xcconfig`) skips the plist with a warning.
    func resolveInfoPlistSetting(
        _ setting: String,
        buildSettings: [String: String],
        warn: (String) -> Void
    ) -> FilePath? {
        let settings = derivedBuildSettings.merging(buildSettings) { _, configured in configured }
        let expanded: String
        do {
            expanded = try expandBuildSettings(in: setting, settings: settings, rawSetting: setting, expanding: [])
        } catch {
            warn("\(error.description) Info.plist of target '\(target.name)' not analyzed.")
            return nil
        }
        let path = FilePath(expanded)

        return path.isAbsolute ? path.lexicallyNormalized() : project.sourceRoot.lexicallyNormalized().appending(expanded).lexicallyNormalized()
    }

    // MARK: - Build settings

    enum BuildSettingError: Error, Equatable, CustomStringConvertible {
        case unresolvedVariable(name: String, setting: String)
        case unsupportedOperator(name: String, setting: String)
        case recursiveVariable(name: String, setting: String)

        var description: String {
            switch self {
            case let .unresolvedVariable(name, setting):
                "Cannot resolve the build setting variable '\(name)' in INFOPLIST_FILE '\(setting)'."
            case let .unsupportedOperator(name, setting):
                "Unsupported build setting operator in '\(name)' in INFOPLIST_FILE '\(setting)'."
            case let .recursiveVariable(name, setting):
                "The build setting variable '\(name)' refers to itself in INFOPLIST_FILE '\(setting)'."
            }
        }
    }

    /// The settings Xcode derives from the project and target.
    private var derivedBuildSettings: [String: String] {
        let sourceRoot = project.sourceRoot.lexicallyNormalized().string
        return [
            "SRCROOT": sourceRoot,
            "SOURCE_ROOT": sourceRoot,
            "PROJECT_DIR": sourceRoot,
            "PROJECT_NAME": project.name,
            "TARGET_NAME": target.name,
        ]
    }

    private func projectConfiguration(named name: String) -> XCBuildConfiguration? {
        project.xcodeProject.pbxproj.rootObject?.buildConfigurationList?.buildConfigurations.first { $0.name == name }
    }

    /// The project configuration's settings of the same name, overridden by the target configuration's.
    private func buildSettings(of configuration: XCBuildConfiguration) -> [String: String] {
        var settings: [String: String] = [:]

        for buildSettings in [projectConfiguration(named: configuration.name)?.buildSettings, configuration.buildSettings].compactMap(\.self) {
            for (key, value) in buildSettings {
                switch value {
                case let .string(string): settings[key] = string
                case let .array(values): settings[key] = values.joined(separator: " ")
                }
            }
        }

        return settings
    }

    private func expandBuildSettings(
        in value: String,
        settings: [String: String],
        rawSetting: String,
        expanding: Set<String>
    ) throws(BuildSettingError) -> String {
        var result = ""
        var remainder = Substring(value)

        while let dollar = remainder.firstIndex(of: "$") {
            result += remainder[..<dollar]
            let afterDollar = remainder.index(after: dollar)

            guard afterDollar < remainder.endIndex,
                  let close: Character = ["(": ")", "{": "}"][remainder[afterDollar]],
                  let end = remainder[afterDollar...].firstIndex(of: close)
            else {
                result.append("$")
                remainder = remainder[afterDollar...]
                continue
            }

            let name = String(remainder[remainder.index(after: afterDollar) ..< end])
            guard !name.contains(":") else {
                throw BuildSettingError.unsupportedOperator(name: name, setting: rawSetting)
            }
            guard !expanding.contains(name) else {
                throw BuildSettingError.recursiveVariable(name: name, setting: rawSetting)
            }
            guard let variableValue = settings[name] else {
                throw BuildSettingError.unresolvedVariable(name: name, setting: rawSetting)
            }

            result += try expandBuildSettings(
                in: variableValue,
                settings: settings,
                rawSetting: rawSetting,
                expanding: expanding.union([name])
            )
            remainder = remainder[remainder.index(after: end)...]
        }

        return result + remainder
    }
}

extension XcodeTarget: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(target.name)
    }
}

extension XcodeTarget: Equatable {
    public static func == (lhs: XcodeTarget, rhs: XcodeTarget) -> Bool {
        lhs.name == rhs.name
    }
}
