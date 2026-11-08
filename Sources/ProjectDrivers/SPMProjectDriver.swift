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
    private let shell: Shell
    private var packageDescription: PackageDescription?
    /// The builds of the `variants` setting, resolved once.
    private var resolvedVariants: [SPMBuildVariant]?

    public convenience init(configuration: Configuration, shell: Shell, logger: Logger) throws {
        if !configuration.schemes.isEmpty {
            throw PeripheryError.usageError("The --schemes option has no effect with Swift Package Manager projects.")
        }

        let pkg = SPM.Package(configuration: configuration, shell: shell, logger: logger)
        self.init(pkg: pkg, configuration: configuration, logger: logger, shell: shell)
    }

    init(pkg: SPM.Package, configuration: Configuration, logger: Logger, shell: Shell) {
        self.pkg = pkg
        self.configuration = configuration
        self.logger = logger
        self.shell = shell
    }

    /// Why some builds of the `variants` setting were not scanned.
    public var skippedVariants: [String] {
        skippedVariantMessages
    }

    private var skippedVariantMessages: [String] = []

    /// The names of the builds scanned together, empty with `variants: default`.
    public var builtVariants: [String] {
        guard configuration.variants != .default else { return [] }

        return resolvedVariants?.map(\.name) ?? []
    }

    private func description() throws -> PackageDescription {
        if let packageDescription {
            return packageDescription
        }

        let description = try pkg.load()
        packageDescription = description
        return description
    }

    private func variants() throws -> [SPMBuildVariant] {
        if let resolvedVariants {
            return resolvedVariants
        }

        let platforms = configuration.variants == .auto ? try description().platforms : nil
        let resolver = SPMVariantResolver(
            shell: shell,
            logger: logger.contextualized(with: "spm:variants"),
            warn: { [unowned self] in
                logger.warn($0)
                skippedVariantMessages.append($0)
            },
            projectPath: pkg.path,
            buildArguments: configuration.buildArguments
        )
        let variants = try resolver.resolve(configuration.variants, platforms: platforms)
        if configuration.variants != .default {
            logger.contextualized(with: "spm:variants").debug("Variants: \(variants.map(\.name).joined(separator: ", "))")
        }
        resolvedVariants = variants
        return variants
    }
}

extension SPMProjectDriver: ProjectDriver {
    public func build() throws {
        if !configuration.skipBuild {
            guard configuration.variants != .default else {
                if configuration.cleanBuild {
                    try pkg.clean()
                }

                if configuration.outputFormat.supportsAuxiliaryOutput {
                    let asterisk = logger.colorize("*", .boldGreen)
                    logger.info("\(asterisk) Building...")
                }

                try pkg.build(additionalArguments: configuration.buildArguments)
                return
            }

            // One build at a time: concurrent builds of the same package would multiply the memory needed.
            for variant in try variants() {
                if configuration.cleanBuild {
                    try pkg.clean(additionalArguments: variant.scratchPath.map { ["--scratch-path", $0.string] } ?? [])
                }

                if configuration.outputFormat.supportsAuxiliaryOutput {
                    let asterisk = logger.colorize("*", .boldGreen)
                    logger.info("\(asterisk) Building \(variant.name)...")
                }

                do {
                    try pkg.build(additionalArguments: configuration.buildArguments + variant.arguments)
                } catch {
                    throw PeripheryError.packageError(message: "The build of the variant '\(variant.name)' failed:\n\(error)")
                }
            }
        }
    }

    public func plan(logger: ContextualLogger) throws -> IndexPlan {
        let indexStorePaths: Set<FilePath> = if !configuration.indexStorePath.isEmpty {
            Set(configuration.indexStorePath)
        } else if configuration.variants == .default {
            try [pkg.indexStorePath(additionalArguments: configuration.buildArguments)]
        } else {
            try variantIndexStorePaths()
        }

        let description = try description()

        let excludedTestTargets = configuration.excludeTests ? testTargetNames(from: description) : []
        let collector = SourceFileCollector(
            indexStorePaths: indexStorePaths,
            excludedTestTargets: excludedTestTargets,
            logger: logger,
            configuration: configuration
        )
        let (sourceFiles, indexExcludedSourceFiles) = try collector.collectWithIndexExcludedFiles()
        let xibPaths = projectFiles(of: .interfaceBuilder, from: description)
        let xcDataModelPaths = projectFiles(of: .xcDataModel, from: description)
        let xcStringsPaths = projectFiles(of: .xcStrings, from: description)

        return IndexPlan(
            sourceFiles: sourceFiles,
            indexExcludedSourceFiles: indexExcludedSourceFiles,
            xibPaths: xibPaths,
            xcDataModelPaths: xcDataModelPaths,
            xcStringsPaths: xcStringsPaths,
            xcStringsModules: projectFileModules(of: .xcStrings, from: description),
            expectedSourceFiles: expectedSourceFiles(from: description, excluding: excludedTestTargets),
            indexStorePaths: indexStorePaths
        )
    }

    // MARK: - Private

    private func variantIndexStorePaths() throws -> Set<FilePath> {
        let variants = try variants()
        let stores = try variants.mapSet { try pkg.indexStorePath(additionalArguments: configuration.buildArguments + $0.arguments) }
        let scratchPaths = variants.compactMap(\.scratchPath)

        if !scratchPaths.isEmpty {
            let evicted = try CacheManager.refresh(
                directories: scratchPaths.map { URL(fileURLWithPath: $0.string) },
                projectPath: pkg.path.lexicallyNormalized().string,
                maxAgeDays: configuration.cacheMaxAgeDays,
                maxSizeGB: configuration.cacheMaxSizeGB
            )
            for entry in evicted {
                let size = ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file)
                logger.info("Evicted unused build cache \(entry.name) (\(size))")
            }
        }

        return stores
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
                for file in FilePath.glob("\(targetPath.string)/**/*.\(ext)") {
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
