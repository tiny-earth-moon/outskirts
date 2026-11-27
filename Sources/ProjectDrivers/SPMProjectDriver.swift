import Configuration
import Extensions
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
    private var resolvedBuilds: [PackageBuild]?

    /// A build of the package: one per variant with `every_variant`, else the single build of the package.
    struct PackageBuild: Equatable {
        let variant: BuildVariant?
        var arguments: [String]
        /// The scratch path of a variant build, where it keeps its products and its index store.
        let scratchPath: FilePath?
        /// The index store a variant build writes to itself, rather than where SwiftPM places it.
        var indexStorePath: FilePath?
    }

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
        guard !configuration.skipBuild else { return }

        for build in try builds() {
            try self.build(build)
        }
    }

    /// Builds the package with the build arguments of `build`; the failure of a variant build names the variant, such
    /// as a triple whose Swift SDK is missing.
    private func build(_ build: PackageBuild) throws {
        if configuration.cleanBuild {
            try pkg.clean(additionalArguments: build.arguments)
        }

        let interval = build.variant.map { logger.beginInterval("driver:build:variant", detail: $0.description) }
        defer {
            if let interval {
                logger.endInterval(interval)
            }
        }

        if configuration.outputFormat.supportsAuxiliaryOutput {
            let asterisk = logger.colorize("*", .boldGreen)
            let variant = build.variant.map { " (\($0))" } ?? ""
            logger.info("\(asterisk) Building\(variant)...")
        }

        do {
            try pkg.build(additionalArguments: build.arguments)
        } catch let error as PeripheryError {
            guard let variant = build.variant, case .shellCommandFailed = error else { throw error }

            throw PeripheryError.packageVariantBuildFailed(variant: variant.description, underlying: error)
        }
    }

    /// The builds of the scan: with `every_variant`, one per variant, each with its own build arguments and its own
    /// scratch path; otherwise the single build with the configured build arguments.
    func builds() throws -> [PackageBuild] {
        if let resolvedBuilds {
            return resolvedBuilds
        }

        let builds: [PackageBuild]
        if configuration.everyVariant {
            let resolution = try BuildVariantResolver(configuration: configuration).swiftPackageVariants()
            for warning in resolution.warnings {
                logger.warn(warning)
            }
            builds = resolution.variants.map { Self.variantBuild($0, buildArguments: configuration.buildArguments, packagePath: pkg.path) }
        } else {
            builds = [PackageBuild(variant: nil, arguments: configuration.buildArguments, scratchPath: nil)]
        }
        resolvedBuilds = builds
        return builds
    }

    /// The build of a variant: the configured build arguments without their scratch path, those of the variant, then a
    /// scratch path of its own, `outskirts-variants/<hash of the other arguments>` in the configured scratch path or
    /// else in `.build`. Variants never share build products, and a scan reuses the incremental build of each variant.
    /// SwiftPM indexes only debug builds, so a release variant has the compiler write its index store in its scratch path.
    static func variantBuild(_ variant: BuildVariant, buildArguments: [String], packagePath: FilePath) -> PackageBuild {
        let (configuredScratchPath, otherArguments) = splitScratchPath(buildArguments)
        let arguments = otherArguments + variant.swiftBuildArguments
        let base = configuredScratchPath.map { packagePath.pushing(FilePath($0)) } ?? packagePath.appending(".build")
        let scratchPath = base.appending("outskirts-variants").appending(arguments.joined(separator: "\n").stableHashHex).lexicallyNormalized()
        var build = PackageBuild(variant: variant, arguments: arguments + ["--scratch-path", scratchPath.string], scratchPath: scratchPath)

        if !variant.isDebug {
            let indexStorePath = scratchPath.appending("index-store")
            build.arguments += ["-Xswiftc", "-index-store-path", "-Xswiftc", indexStorePath.string]
            build.indexStorePath = indexStorePath
        }
        return build
    }

    /// The last scratch path of `arguments`, given by `--scratch-path` or its older name `--build-path`, and the other
    /// arguments; an argument forwarded to the compiler or the linker is never a scratch path.
    static func splitScratchPath(_ arguments: [String]) -> (scratchPath: String?, others: [String]) {
        let options: Set = ["--scratch-path", "--build-path"]
        var scratchPath: String?
        var others: [String] = []
        var index = arguments.startIndex

        while index < arguments.endIndex {
            let argument = arguments[index]
            index += 1

            if BuildVariantResolver.forwardingOptions.contains(argument), index < arguments.endIndex {
                others += [argument, arguments[index]]
                index += 1
            } else if let separator = argument.firstIndex(of: "="), options.contains(String(argument[..<separator])) {
                scratchPath = String(argument[argument.index(after: separator)...])
            } else if options.contains(argument), index < arguments.endIndex {
                scratchPath = arguments[index]
                index += 1
            } else {
                others.append(argument)
            }
        }
        return (scratchPath, others)
    }

    /// The index store of each variant build; a variant left unbuilt, e.g. by `skip_build`, fails naming it.
    func variantIndexStorePaths(_ builds: [PackageBuild]) throws -> Set<FilePath> {
        try builds.mapSet { build in
            let notFound = PeripheryError.variantIndexStoreNotFound(variant: build.variant?.description ?? "", derivedDataPath: build.scratchPath?.string ?? "")
            if let indexStorePath = build.indexStorePath {
                guard indexStorePath.appending("v5").exists else { throw notFound }

                return indexStorePath
            }

            do {
                return try pkg.indexStorePath(additionalArguments: build.arguments)
            } catch PeripheryError.spmIndexStoreNotFound {
                throw notFound
            }
        }
    }

    /// Whether the plan reads the index stores of the variant builds rather than those of `index_store_path` or of the
    /// single build.
    private var readsVariantIndexStores: Bool {
        configuration.everyVariant && configuration.indexStorePath.isEmpty
    }

    public func plan(logger: ContextualLogger) throws -> IndexPlan {
        let indexStorePaths = if readsVariantIndexStores {
            try variantIndexStorePaths(builds())
        } else {
            try resolveIndexStorePaths(configured: configuration.indexStorePath) {
                try pkg.indexStorePath(additionalArguments: configuration.buildArguments)
            }
        }

        // Load package description once and reuse it
        let description = try pkg.load()

        let excludedTargets = excludedTargets(of: description)
        warnUnmatchedExcludedTargets(configuration.excludeTargets, targets: description.targets.flatMap { [$0.name, $0.c99name].compactMap(\.self) }, logger: logger)
        let xibPaths = projectFiles(of: .interfaceBuilder, from: description)
        let xcDataModelPaths = projectFiles(of: .xcDataModel, from: description)
        let xcStringsPaths = projectFiles(of: .xcStrings, from: description)
        let expectedSourceFiles = expectedSourceFiles(from: description, excluding: excludedTargets.mapSet(\.name))
        let collector = SourceFileCollector(
            indexStorePaths: indexStorePaths,
            excludedModules: excludedTargets.mapSet(\.moduleName),
            testModules: Self.testModules(of: description),
            scanInputs: ScanInputs(
                sourceFiles: Set(expectedSourceFiles.values.joined()),
                resources: xibPaths.union(xcDataModelPaths).union(xcStringsPaths),
                readsMetalSources: configuration.detectUnusedMetalFunctions,
                readsAssetCatalogs: configuration.detectsUnusedAssetCatalogSymbols
            ),
            logger: logger,
            configuration: configuration
        )
        let (sourceFiles, unreadableUnits) = try collector.collect()

        return IndexPlan(
            sourceFiles: sourceFiles,
            xibPaths: xibPaths,
            xcDataModelPaths: xcDataModelPaths,
            xcStringsPaths: xcStringsPaths,
            xcStringsModules: projectFileModules(of: .xcStrings, from: description),
            expectedSourceFiles: expectedSourceFiles,
            coverageTargets: configuration.strictIndexCoverage ? try coverageTargets(of: description.targets.filter { expectedSourceFiles.keys.contains($0.name) }) : [:],
            unreadableUnits: unreadableUnits,
            indexStorePaths: indexStorePaths
        )
    }

    // MARK: - Private

    /// Every target is expected on the platform the package is built for: the platform of a `--triple` build argument,
    /// else the host; any platform with `--swift-sdk` or a triple of an unknown system, whose platform is not known
    /// here, and with an index store given by `--index-store-path` without `--triple`, which may come from any build.
    /// With `every_variant`, the platforms of all the variants.
    func coverageTargets(of targets: [Target]) throws -> [String: CoverageTarget] {
        let platforms = if readsVariantIndexStores {
            try Self.variantPlatforms(builds())
        } else {
            Self.buildPlatforms(arguments: configuration.buildArguments, externalIndexStore: !configuration.indexStorePath.isEmpty)
        }

        return Dictionary(uniqueKeysWithValues: targets.map { ($0.name, CoverageTarget(moduleName: $0.moduleName, platforms: platforms)) })
    }

    /// The platforms the variant builds compile for; any platform as soon as one of them is not known here.
    static func variantPlatforms(_ builds: [PackageBuild]) -> Set<IndexPlatform> {
        var platforms: Set<IndexPlatform> = []
        for build in builds {
            let buildPlatforms = buildPlatforms(arguments: build.arguments, externalIndexStore: false)
            guard !buildPlatforms.isEmpty else { return [] }

            platforms.formUnion(buildPlatforms)
        }
        return platforms
    }

    static func buildPlatforms(arguments: [String], externalIndexStore: Bool) -> Set<IndexPlatform> {
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

        return externalIndexStore ? [] : [.host]
    }

    func expectedSourceFiles(from description: PackageDescription, excluding excluded: Set<String>) -> [String: Set<FilePath>] {
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

    /// The modules of the test targets, and the modules SwiftPM generates to discover and run their tests where the
    /// Objective-C runtime is missing: `<Package>PackageDiscoveredTests` and `<Package>PackageTests`, or one
    /// `<TestTarget>_test_runner` per test target, depending on the SwiftPM version, on Linux.
    static func testModules(of description: PackageDescription) -> Set<String> {
        let modules = description.targets.filter(\.isTestTarget).mapSet(\.moduleName)
        guard !modules.isEmpty else { return modules }

        let runners = modules.map { $0 + "_test_runner" }
        guard let name = description.name else { return modules.union(runners) }

        let generated = ["PackageDiscoveredTests", "PackageTests"].map { c99Identifier(name + $0) }
        return modules.union(runners).union(generated)
    }

    /// The name made a C identifier, as SwiftPM names a module: each character that is not a letter, a digit or `_`
    /// becomes `_`, and a leading digit is prefixed with `_`.
    private static func c99Identifier(_ name: String) -> String {
        let identifier = String(name.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") ? $0 : "_" })
        return identifier.first?.isNumber == true ? "_" + identifier : identifier
    }

    /// The test targets with `exclude_tests`, and the targets `exclude_targets` names by target or module name.
    func excludedTargets(of description: PackageDescription) -> [Target] {
        description.targets.filter { target in
            (configuration.excludeTests && target.isTestTarget)
                || configuration.excludeTargets.contains(target.name)
                || configuration.excludeTargets.contains(target.moduleName)
        }
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
            let module = target.moduleName
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
