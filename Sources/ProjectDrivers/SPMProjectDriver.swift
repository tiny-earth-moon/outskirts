import Configuration
import Foundation
import Indexer
import IndexStore
import Logger
import Shared
import SourceGraph
import SystemPackage

public final class SPMProjectDriver {
    private let pkg: SPM.Package
    private let configuration: Configuration
    private let logger: Logger

    public convenience init(configuration: Configuration, shell: Shell, logger: Logger) throws {
        if !configuration.schemes.isEmpty {
            throw PeripheryError.usageError("The --schemes option has no effect with Swift Package Manager projects.")
        }

        let pkg = SPM.Package(configuration: configuration, shell: shell, logger: logger)
        self.init(pkg: pkg, configuration: configuration, logger: logger)
    }

    init(pkg: SPM.Package, configuration: Configuration, logger: Logger) {
        self.pkg = pkg
        self.configuration = configuration
        self.logger = logger
    }
}

extension SPMProjectDriver: ProjectDriver {
    public func build() throws {
        if !configuration.skipBuild {
            if configuration.cleanBuild {
                try pkg.clean()
            }

            if configuration.outputFormat.supportsAuxiliaryOutput {
                let asterisk = logger.colorize("*", .boldGreen)
                logger.info("\(asterisk) Building...")
            }

            try pkg.build(additionalArguments: configuration.buildArguments)
        }
    }

    public func plan(logger: ContextualLogger) throws -> IndexPlan {
        let indexStorePaths = try resolveIndexStorePaths(configured: configuration.indexStorePath) {
            try pkg.indexStorePath(additionalArguments: configuration.buildArguments)
        }

        // Load package description once and reuse it
        let description = try pkg.load()

        let excludedTestTargets = configuration.excludeTests ? testTargetNames(from: description) : []
        let collector = SourceFileCollector(
            indexStorePaths: indexStorePaths,
            excludedTestTargets: excludedTestTargets,
            logger: logger,
            configuration: configuration
        )
        let (sourceFiles, unreadableUnits) = try collector.collect()
        let xibPaths = projectFiles(of: .interfaceBuilder, from: description)
        let xcDataModelPaths = projectFiles(of: .xcDataModel, from: description)
        let xcStringsPaths = projectFiles(of: .xcStrings, from: description)
        let expectedSourceFiles = expectedSourceFiles(from: description, excluding: excludedTestTargets)

        return IndexPlan(
            sourceFiles: sourceFiles,
            xibPaths: xibPaths,
            xcDataModelPaths: xcDataModelPaths,
            xcStringsPaths: xcStringsPaths,
            xcStringsModules: projectFileModules(of: .xcStrings, from: description),
            expectedSourceFiles: expectedSourceFiles,
            coverageTargets: configuration.strictIndexCoverage ? coverageTargets(of: expectedSourceFiles.keys) : [:],
            unreadableUnits: unreadableUnits,
            indexStorePaths: indexStorePaths
        )
    }

    // MARK: - Private

    /// Every target is expected on the platform the package is built for: the host, or the platform of a `--triple`
    /// build argument; any platform with `--swift-sdk`, whose platform is not known here.
    func coverageTargets(of targets: some Sequence<String>) -> [String: CoverageTarget] {
        let platforms = Self.buildPlatforms(arguments: configuration.buildArguments)

        return Dictionary(uniqueKeysWithValues: targets.map { ($0, CoverageTarget(moduleName: $0, platforms: platforms)) })
    }

    static func buildPlatforms(arguments: [String]) -> Set<IndexPlatform> {
        for (index, argument) in arguments.enumerated() {
            if argument == "--swift-sdk" || argument.hasPrefix("--swift-sdk=") {
                return []
            }
            if argument.hasPrefix("--triple=") {
                return IndexPlatform(triple: String(argument.dropFirst("--triple=".count))).map { [$0] } ?? []
            }
            if argument == "--triple" {
                return arguments.indices.contains(index + 1) ? IndexPlatform(triple: arguments[index + 1]).map { [$0] } ?? [] : []
            }
        }

        return [.host]
    }

    func expectedSourceFiles(from description: PackageDescription, excluding excludedTargets: Set<String>) -> [String: Set<FilePath>] {
        let excluded = excludedTargets.union(configuration.excludeTargets)
        var result: [String: Set<FilePath>] = [:]

        for target in description.targets where !excluded.contains(target.name) {
            let targetPath = pkg.path.appending(target.path)
            let files = (target.sources ?? [])
                .filter { $0.hasSuffix(".swift") }
                .mapSet { targetPath.appending($0).lexicallyNormalized() }

            if !files.isEmpty {
                result[target.name] = files
            }
        }

        return result
    }

    private func testTargetNames(from description: PackageDescription) -> Set<String> {
        description.targets.filter(\.isTestTarget).mapSet(\.name)
    }

    private func projectFiles(of kind: ProjectFileKind, from description: PackageDescription) -> Set<FilePath> {
        Set(projectFileModules(of: kind, from: description).keys)
    }

    /// The project files of a kind, each with the modules of the targets containing it.
    private func projectFileModules(of kind: ProjectFileKind, from description: PackageDescription) -> [FilePath: Set<String>] {
        var files: [FilePath: Set<String>] = [:]
        let extensions = kind.extensions

        for target in description.targets {
            let targetPath = pkg.path.appending(target.path)
            let module = target.c99name ?? target.name
            var targetFiles: Set<FilePath> = []

            // SwiftPM processes Interface Builder files and Core Data models implicitly, without a `resources:` declaration,
            // and `swift package describe` only lists the declared resources.
            for ext in extensions {
                for file in FilePath.glob("\(targetPath.string)/**/*.\(ext)", onUnreadableDirectory: logger.warnUnreadableDirectory) {
                    // SwiftPM ignores hidden files and directories, such as `.build` and `.scratch`.
                    let relativeComponents = file.components.dropFirst(targetPath.components.count)
                    guard !relativeComponents.contains(where: { $0.string.hasPrefix(".") }) else { continue }

                    targetFiles.insert(file)
                }
            }

            for resource in target.resources ?? [] {
                // Resource.path is always a single file path
                let resourceFilePath = FilePath(resource.path)
                let resourcePath: FilePath = resourceFilePath.isAbsolute
                    ? resourceFilePath
                    : targetPath.appending(resource.path)

                // Check if the resource path exists and has an extension of this kind
                guard resourcePath.exists else { continue }
                guard let ext = resourcePath.extension?.lowercased(), extensions.contains(ext) else { continue }

                targetFiles.insert(resourcePath.lexicallyNormalized())
            }

            for file in targetFiles {
                files[file, default: []].insert(module)
            }
        }

        return files
    }
}
