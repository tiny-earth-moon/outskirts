#if os(macOS)
    import Configuration
    import Foundation
    import Indexer
    import Logger
    import Shared
    import SourceGraph
    import SystemPackage
    import XcodeSupport

    public final class XcodeProjectDriver {
        private let logger: Logger
        private let configuration: Configuration
        private let xcodebuild: Xcodebuild
        private let project: XcodeProjectlike
        private let schemes: Set<String>
        private let shell: Shell
        /// The builds of the `variants` setting, resolved once.
        private var resolvedVariants: [XcodeBuildVariant]?
        /// The DerivedData folders of this scan, locked so that concurrent scans never evict them.
        private let cacheLease = CacheLease()

        public convenience init(
            projectPath: FilePath,
            configuration: Configuration,
            shell: Shell,
            logger: Logger,
            cacheDirectory: FilePath? = nil
        ) throws {
            if configuration.outputFormat.supportsAuxiliaryOutput {
                let asterisk = logger.colorize("*", .boldGreen)
                logger.info("\(asterisk) Inspecting project...")
            }

            let xcodebuild = Xcodebuild(shell: shell, logger: logger, cacheDirectory: cacheDirectory)

            guard !configuration.schemes.isEmpty else {
                throw PeripheryError.usageError("The '--schemes' option is required.")
            }

            try xcodebuild.ensureConfigured()

            let project: XcodeProjectlike
            if projectPath.extension == "xcworkspace" {
                project = try XcodeWorkspace(
                    path: .makeAbsolute(projectPath),
                    xcodebuild: xcodebuild,
                    configuration: configuration,
                    logger: logger,
                    shell: shell
                )
            } else {
                var loadedProjectPaths: Set<FilePath> = []
                project = try XcodeProject(
                    path: .makeAbsolute(projectPath),
                    loadedProjectPaths: &loadedProjectPaths,
                    xcodebuild: xcodebuild,
                    shell: shell,
                    logger: logger
                )
            }

            let schemes: Set<String>

            if configuration.skipSchemesValidation {
                schemes = Set(configuration.schemes)
            } else {
                // Ensure schemes exist within the project
                if configuration.cleanBuild {
                    try xcodebuild.removeDerivedData(for: project, allSchemes: [])
                }
                schemes = try project.schemes(
                    additionalArguments: configuration.xcodeListArguments
                ).filter { configuration.schemes.contains($0) }
                let validSchemeNames = schemes.mapSet { $0 }

                if let scheme = Set(configuration.schemes).subtracting(validSchemeNames).first {
                    throw PeripheryError.invalidScheme(name: scheme, project: project.path.lastComponent?.string ?? "")
                }
            }

            self.init(
                logger: logger,
                configuration: configuration,
                xcodebuild: xcodebuild,
                project: project,
                schemes: schemes,
                shell: shell
            )
        }

        init(
            logger: Logger,
            configuration: Configuration,
            xcodebuild: Xcodebuild,
            project: XcodeProjectlike,
            schemes: Set<String>,
            shell: Shell
        ) {
            self.logger = logger
            self.configuration = configuration
            self.xcodebuild = xcodebuild
            self.project = project
            self.schemes = schemes
            self.shell = shell
        }

        /// Why some builds of the `variants` setting were not scanned.
        public var skippedVariants: [String] {
            skippedVariantMessages
        }

        private var skippedVariantMessages: [String] = []

        /// The names of the variants this run built, empty with `variants: default`, `--skip-build` or
        /// `--index-store-path`: an index store left by an earlier build may not match the sources.
        public var builtVariants: [String] {
            guard configuration.variants != .default, configuration.indexStorePath.isEmpty else { return [] }

            return builtVariantNames
        }

        private var builtVariantNames: [String] = []

        private func variants() throws -> [XcodeBuildVariant] {
            if let resolvedVariants {
                return resolvedVariants
            }

            let variantLogger = logger.contextualized(with: "xcode:variants")
            let resolver = XcodeVariantResolver(
                shell: shell,
                warn: { [unowned self] in
                    logger.warn($0)
                    skippedVariantMessages.append($0)
                },
                buildArguments: configuration.buildArguments
            )
            let variants = try resolver.resolve(configuration.variants) {
                try xcodebuild.supportedPlatforms(project: project, schemes: Array(schemes), additionalArguments: configuration.buildArguments)
            }
            if configuration.variants != .default {
                variantLogger.debug("Variants: \(variants.map(\.name).joined(separator: ", "))")
            }
            resolvedVariants = variants
            return variants
        }

        /// The build arguments of each build: those of the scan alone with `variants: default`.
        private func buildArgumentsOfEachBuild() throws -> [[String]] {
            guard configuration.variants != .default else { return [configuration.buildArguments] }

            return try variants().map { configuration.buildArguments + $0.arguments }
        }
    }

    extension XcodeProjectDriver: ProjectDriver {
        public func build() throws {
            guard !configuration.skipBuild else { return }
            guard configuration.variants == .default else {
                try buildVariants()
                return
            }

            if configuration.cleanBuild {
                try xcodebuild.removeDerivedData(for: project, allSchemes: Array(schemes), buildArguments: configuration.buildArguments)
            }
            holdCache(buildArguments: configuration.buildArguments, creating: true)

            for scheme in schemes {
                if configuration.outputFormat.supportsAuxiliaryOutput {
                    let asterisk = logger.colorize("*", .boldGreen)
                    logger.info("\(asterisk) Building \(scheme)...")
                }

                try xcodebuild.build(project: project,
                                     scheme: scheme,
                                     allSchemes: Array(schemes),
                                     additionalArguments: configuration.buildArguments)
            }
        }

        public func plan(logger: ContextualLogger) throws -> IndexPlan {
            if configuration.indexStorePath.isEmpty {
                for buildArguments in try buildArgumentsOfEachBuild() {
                    holdCache(buildArguments: buildArguments, creating: false)
                }
            }

            let indexStorePaths: Set<FilePath> = if !configuration.indexStorePath.isEmpty {
                Set(configuration.indexStorePath)
            } else {
                try buildArgumentsOfEachBuild().mapSet {
                    try xcodebuild.indexStorePath(project: project, schemes: Array(schemes), buildArguments: $0, skipBuild: configuration.skipBuild)
                }
            }

            if configuration.indexStorePath.isEmpty {
                try xcodebuild.refreshCache(
                    project: project,
                    schemes: Array(schemes),
                    buildArgumentsOfEachBuild: buildArgumentsOfEachBuild(),
                    maxAgeDays: configuration.cacheMaxAgeDays,
                    maxSizeGB: configuration.cacheMaxSizeGB
                ).report(to: self.logger)
            }

            let targets = project.targets
            try targets.forEach { try $0.identifyFiles() }
            let excludedTestTargets = configuration.excludeTests ? project.targets.filter(\.isTestTarget).mapSet(\.name) : []
            let collector = SourceFileCollector(
                indexStorePaths: indexStorePaths,
                excludedTestTargets: excludedTestTargets,
                logger: logger,
                configuration: configuration
            )
            let (sourceFiles, indexExcludedSourceFiles, unreadableUnits) = try collector.collectWithIndexExcludedFiles()
            let excluded = excludedTestTargets.union(configuration.excludeTargets)
            let expectedSourceFiles = targets
                .filter { !excluded.contains($0.name) && !$0.swiftSourceFiles.isEmpty }
                .reduce(into: [String: Set<FilePath>]()) { $0[$1.name, default: []].formUnion($1.swiftSourceFiles) }
            let infoPlistPaths = targets.flatMapSet { $0.files(kind: .infoPlist) }
            let xibPaths = targets.flatMapSet { $0.files(kind: .interfaceBuilder) }
            let xcDataModelPaths = targets.flatMapSet { $0.files(kind: .xcDataModel) }
            let xcMappingModelPaths = targets.flatMapSet { $0.files(kind: .xcMappingModel) }
            let xcStringsPaths = targets.flatMapSet { $0.files(kind: .xcStrings) }

            return IndexPlan(
                sourceFiles: sourceFiles,
                indexExcludedSourceFiles: indexExcludedSourceFiles,
                plistPaths: infoPlistPaths,
                xibPaths: xibPaths,
                xcDataModelPaths: xcDataModelPaths,
                xcMappingModelPaths: xcMappingModelPaths,
                xcStringsPaths: xcStringsPaths,
                expectedSourceFiles: expectedSourceFiles,
                unreadableUnits: unreadableUnits,
                indexStorePaths: indexStorePaths,
                globalAccentColorNames: targets.flatMapSet(\.globalAccentColorNames)
            )
        }

        // MARK: - Private

        /// Holds the DerivedData folder of a build. A failure is a warning: the cache housekeeping never fails the scan.
        private func holdCache(buildArguments: [String], creating: Bool) {
            do {
                try xcodebuild.holdCache(cacheLease, project: project, schemes: Array(schemes), buildArguments: buildArguments, creating: creating)
            } catch {
                logger.warn("Could not lock the build cache folder of this scan: \(error.localizedDescription)")
            }
        }

        /// One build of the schemes per variant, one after the other: concurrent builds would multiply the memory needed.
        private func buildVariants() throws {
            for variant in try variants() {
                let buildArguments = configuration.buildArguments + variant.arguments
                if configuration.cleanBuild {
                    try xcodebuild.removeDerivedData(for: project, allSchemes: Array(schemes), buildArguments: buildArguments)
                }
                holdCache(buildArguments: buildArguments, creating: true)

                for scheme in schemes {
                    if configuration.outputFormat.supportsAuxiliaryOutput {
                        let asterisk = logger.colorize("*", .boldGreen)
                        logger.info("\(asterisk) Building \(scheme) for \(variant.name)...")
                    }

                    do {
                        try xcodebuild.build(project: project, scheme: scheme, allSchemes: Array(schemes), additionalArguments: buildArguments)
                    } catch {
                        throw PeripheryError.packageError(message: "The build of the variant '\(variant.name)' failed:\n\(error)")
                    }
                }
                builtVariantNames.append(variant.name)
            }
        }
    }
#endif
