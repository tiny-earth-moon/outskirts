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
        private var resolvedBuilds: [SchemeBuild]?

        /// The targets of each scheme whose `.xcscheme` file names targets of the project.
        private lazy var schemeTargets: [String: XcodeSchemeTargets] = schemes.reduce(into: [:]) { result, scheme in
            result[scheme] = XcodeSchemeTargets.load(scheme: scheme, in: project) { logger.warn($0) }
        }

        /// A build of the schemes: one per variant with `every_variant`, else the single build of the project.
        struct SchemeBuild: Equatable {
            let variant: BuildVariant?
            let arguments: [String]
            /// The schemes this build builds: with `every_variant`, those whose targets support the platform of the
            /// variant.
            let schemes: [String]
        }

        public convenience init(
            projectPath: FilePath,
            configuration: Configuration,
            shell: Shell,
            logger: Logger,
            cacheDirectory: FilePath? = nil
        ) throws {
            let absolutePath: FilePath = .makeAbsolute(projectPath)
            guard absolutePath.exists else {
                throw PeripheryError.projectNotFound(path: absolutePath.string)
            }

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
                schemes: schemes
            )
        }

        init(
            logger: Logger,
            configuration: Configuration,
            xcodebuild: Xcodebuild,
            project: XcodeProjectlike,
            schemes: Set<String>
        ) {
            self.logger = logger
            self.configuration = configuration
            self.xcodebuild = xcodebuild
            self.project = project
            self.schemes = schemes
        }
    }

    extension XcodeProjectDriver: ProjectDriver {
        public func build() throws {
            guard !configuration.skipBuild else { return }

            for build in try builds() {
                try self.build(build)
            }
        }

        /// Builds every scheme with the build arguments of `build`, in its own DerivedData folder.
        private func build(_ build: SchemeBuild) throws {
            if configuration.cleanBuild {
                try xcodebuild.removeDerivedData(for: project, allSchemes: Array(schemes), buildArguments: build.arguments)
            }

            let interval = build.variant.map { logger.beginInterval("driver:build:variant", detail: $0.description) }
            defer {
                if let interval {
                    logger.endInterval(interval)
                }
            }

            for scheme in build.schemes {
                if configuration.outputFormat.supportsAuxiliaryOutput {
                    let asterisk = logger.colorize("*", .boldGreen)
                    let variant = build.variant.map { " (\($0))" } ?? ""
                    logger.info("\(asterisk) Building \(scheme)\(variant)...")
                }

                try self.build(scheme: scheme, build: build)
            }
        }

        /// The builds of the scan: with `every_variant`, one per variant, each with its own build arguments and thus
        /// its own DerivedData folder, of the schemes whose targets support its platform; otherwise the single build of
        /// every scheme with the configured build arguments.
        func builds() throws -> [SchemeBuild] {
            if let resolvedBuilds {
                return resolvedBuilds
            }

            let builds: [SchemeBuild]
            if configuration.everyVariant {
                let resolver = BuildVariantResolver(configuration: configuration)
                try resolver.validate()
                let projectTargetSDKs = Self.sdks(of: project.targets.subtracting(excludedTargets()))
                let targetSDKs = try BuildVariantResolver.resolvingUnknownSDKs(
                    schemes: Array(schemes),
                    schemeTargetSDKs: schemeTargetSDKs(),
                    projectTargetSDKs: projectTargetSDKs
                ) { scheme in
                    try xcodebuild.supportedSDKs(project: project, scheme: scheme, additionalArguments: configuration.buildArguments)
                }
                let resolution = try resolver.xcodeVariants(
                    schemes: Array(schemes),
                    schemeTargetSDKs: targetSDKs,
                    projectTargetSDKs: projectTargetSDKs,
                    projectConfigurations: projectConfigurationNames()
                )
                for warning in resolution.warnings {
                    logger.warn(warning)
                }
                builds = resolution.variants.map {
                    SchemeBuild(variant: $0, arguments: configuration.buildArguments + $0.xcodebuildArguments, schemes: resolution.schemes[$0] ?? [])
                }
            } else {
                builds = [SchemeBuild(variant: nil, arguments: configuration.buildArguments, schemes: schemes.sorted())]
            }
            resolvedBuilds = builds
            return builds
        }

        /// Builds a scheme; the failure of a variant build names the variant, such as a platform whose SDK is missing.
        private func build(scheme: String, build: SchemeBuild) throws {
            do {
                try xcodebuild.build(project: project, scheme: scheme, allSchemes: Array(schemes), additionalArguments: build.arguments)
            } catch let error as PeripheryError {
                guard let variant = build.variant, case .shellCommandFailed = error else { throw error }

                throw PeripheryError.variantBuildFailed(variant: variant.description, scheme: scheme, underlying: error)
            }
        }

        private func excludedTargets() -> Set<XcodeTarget> {
            Self.excludedTargets(of: project.targets, excludeTests: configuration.excludeTests, excludeTargets: configuration.excludeTargets)
        }

        /// The SDK names each target the scheme names supports, by target name, for each scheme of known targets. The
        /// excluded targets are left out, unless the scheme names only excluded targets.
        private func schemeTargetSDKs() -> [String: [String: Set<String>]] {
            let excluded = excludedTargets()
            return schemeTargets.mapValues { targets in
                let scanned = targets.named.subtracting(excluded)
                return Self.sdks(of: scanned.isEmpty ? targets.named : scanned)
            }
        }

        /// The SDK names each target supports, by target name.
        private static func sdks(of targets: Set<XcodeTarget>) -> [String: Set<String>] {
            targets.reduce(into: [:]) { $0[$1.name, default: []].formUnion($1.supportedSDKs) }
        }

        /// The platforms of the variants that build the target: those of the schemes whose targets include it, else,
        /// for a target outskirts cannot tell the schemes of, those of every variant.
        func variantPlatforms(of target: XcodeTarget, builds: [SchemeBuild]) -> Set<IndexPlatform> {
            let builders = Set(schemes.filter { schemeTargets[$0]?.built.contains(target) ?? true })
            let builtBy = builders.isEmpty ? builds : builds.filter { !builders.isDisjoint(with: $0.schemes) }
            return builtBy.compactMapSet { $0.variant?.platform.indexPlatform }
        }

        /// The build configurations of the project, then those of the other projects of its targets.
        private func projectConfigurationNames() -> [String] {
            let own = project as? XcodeProject
            let others = Set(project.targets.map(\.project)).filter { $0 !== own }.sorted { $0.path.string < $1.path.string }
            return ([own].compactMap(\.self) + others).flatMap(\.buildConfigurationNames)
        }

        /// The index store of each variant build; a variant left unbuilt, e.g. by `skip_build`, fails naming it.
        func variantIndexStorePaths(_ builds: [SchemeBuild]) throws -> Set<FilePath> {
            try builds.mapSet { build in
                do {
                    return try xcodebuild.indexStorePath(project: project, schemes: Array(schemes), buildArguments: build.arguments)
                } catch let PeripheryError.indexStoreNotFound(derivedDataPath) {
                    throw PeripheryError.variantIndexStoreNotFound(variant: build.variant?.description ?? "", derivedDataPath: derivedDataPath)
                }
            }
        }

        /// Refreshes the build cache entries in use and evicts the unused ones; a configured index store bypasses the cache.
        private func evictUnusedBuildCaches() throws {
            guard configuration.indexStorePath.isEmpty else { return }

            let evicted = try xcodebuild.refreshCache(
                project: project,
                schemes: Array(schemes),
                buildArgumentSets: builds().map(\.arguments),
                maxAgeDays: configuration.cacheMaxAgeDays,
                maxSizeGB: configuration.cacheMaxSizeGB
            )
            for entry in evicted {
                let size = ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file)
                logger.info("Evicted unused build cache \(entry.name) (\(size))")
            }
        }

        public func plan(logger: ContextualLogger) throws -> IndexPlan {
            let indexStorePaths = if configuration.everyVariant, configuration.indexStorePath.isEmpty {
                try variantIndexStorePaths(builds())
            } else {
                try resolveIndexStorePaths(configured: configuration.indexStorePath) {
                    try xcodebuild.indexStorePath(project: project, schemes: Array(schemes), buildArguments: configuration.buildArguments, skipBuild: configuration.skipBuild)
                }
            }

            try evictUnusedBuildCaches()

            let targets = project.targets
            try targets.forEach { try $0.identifyFiles() }
            let excludedTargets = Self.excludedTargets(of: targets, excludeTests: configuration.excludeTests, excludeTargets: configuration.excludeTargets)
            warnUnmatchedExcludedTargets(configuration.excludeTargets, targets: targets.flatMap { [$0.name, $0.moduleName].compactMap(\.self) }, logger: logger)
            let scannedTargets = Self.scannedTargets(of: targets.subtracting(excludedTargets), excluding: [], relativeTo: project.sourceRoot)
            let expectedSourceFiles = scannedTargets.mapValues(\.swiftSourceFiles)
            let infoPlistPaths = targets.flatMapSet { $0.files(kind: .infoPlist) }
            let xibPaths = targets.flatMapSet { $0.files(kind: .interfaceBuilder) }
            let xcDataModelPaths = targets.flatMapSet { $0.files(kind: .xcDataModel) }
            let xcMappingModelPaths = targets.flatMapSet { $0.files(kind: .xcMappingModel) }
            let xcStringsPaths = targets.flatMapSet { $0.files(kind: .xcStrings) }
            let collector = SourceFileCollector(
                indexStorePaths: indexStorePaths,
                excludedModules: excludedTargets.mapSet { $0.moduleName ?? $0.name },
                testModules: Self.testModules(of: targets),
                scanInputs: ScanInputs(
                    sourceFiles: Set(expectedSourceFiles.values.joined()),
                    resources: infoPlistPaths.union(xibPaths).union(xcDataModelPaths).union(xcMappingModelPaths).union(xcStringsPaths),
                    readsMetalSources: configuration.detectUnusedMetalFunctions,
                    readsAssetCatalogs: configuration.detectsUnusedAssetCatalogSymbols
                ),
                logger: logger,
                configuration: configuration
            )
            let (sourceFiles, unreadableUnits) = try collector.collect()
            let variantBuilds = configuration.everyVariant ? try builds() : nil
            let variantPlatforms = variantBuilds.map { builds in { (target: XcodeTarget) in self.variantPlatforms(of: target, builds: builds) } }
            let coverageTargets = configuration.strictIndexCoverage ? Self.coverageTargets(of: scannedTargets, variantPlatforms: variantPlatforms) : [:]

            return IndexPlan(
                sourceFiles: sourceFiles,
                plistPaths: infoPlistPaths,
                xibPaths: xibPaths,
                xcDataModelPaths: xcDataModelPaths,
                xcMappingModelPaths: xcMappingModelPaths,
                xcStringsPaths: xcStringsPaths,
                expectedSourceFiles: expectedSourceFiles,
                coverageTargets: coverageTargets,
                unreadableUnits: unreadableUnits,
                indexStorePaths: indexStorePaths,
                globalAccentColorNames: targets.flatMapSet(\.globalAccentColorNames)
            )
        }

        /// The test targets with `exclude_tests`, and the targets `exclude_targets` names by target or module name.
        static func excludedTargets(of targets: Set<XcodeTarget>, excludeTests: Bool, excludeTargets: [String]) -> Set<XcodeTarget> {
            targets.filter { target in
                (excludeTests && target.isTestTarget)
                    || excludeTargets.contains(target.name)
                    || target.moduleName.map(excludeTargets.contains) == true
            }
        }

        /// The modules of the test targets, which index units name.
        static func testModules(of targets: Set<XcodeTarget>) -> Set<String> {
            targets.filter(\.isTestTarget).mapSet { $0.moduleName ?? $0.name }
        }

        /// The targets with Swift source files, minus the excluded names, keyed by name. A name shared by targets of
        /// several projects (e.g. in a workspace) is qualified with the path of each project, relative to `base`.
        static func scannedTargets(of targets: Set<XcodeTarget>, excluding excluded: Set<String>, relativeTo base: FilePath) -> [String: XcodeTarget] {
            let scanned = targets.filter { !excluded.contains($0.name) && !$0.swiftSourceFiles.isEmpty }
            let base = base.lexicallyNormalized()

            return Dictionary(grouping: scanned, by: \.name).reduce(into: [:]) { result, group in
                guard group.value.count > 1 else {
                    result[group.key] = group.value.first
                    return
                }

                for target in group.value {
                    let path = target.project.path.lexicallyNormalized()
                    let shown = path.starts(with: base) ? path.relativeTo(base) : path
                    result["\(group.key) (\(shown.string))"] = target
                }
            }
        }

        /// The platforms each target is expected to have index data for: those it supports, and with `every_variant`
        /// only those of the variants that build it.
        static func coverageTargets(
            of targets: [String: XcodeTarget],
            variantPlatforms: ((XcodeTarget) -> Set<IndexPlatform>)? = nil
        ) -> [String: CoverageTarget] {
            targets.mapValues { target in
                let platforms = target.supportedSDKs.compactMapSet(IndexPlatform.init(sdk:))
                return CoverageTarget(moduleName: target.moduleName, platforms: variantPlatforms.map { platforms.intersection($0(target)) } ?? platforms)
            }
        }
    }
#endif
