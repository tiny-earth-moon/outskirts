import ArgumentParser
import Configuration
import Foundation
import Logger
import PeripheryKit
import Shared
import SourceGraph
import SystemPackage

struct ScanCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scan",
        abstract: "Scan for unused code"
    )

    @Argument(help: "Arguments following '--' will be passed to the underlying build tool, which is either 'swift build' or 'xcodebuild' depending on your project")
    var buildArguments: [String] = defaultConfiguration.$buildArguments.defaultValue

    @OptionGroup(title: "Project")
    var projectOptions: ProjectOptions

    @OptionGroup(title: "Build")
    var buildOptions: BuildOptions

    @OptionGroup(title: "Analysis")
    var analysisOptions: AnalysisOptions

    @OptionGroup(title: "Retention")
    var retentionOptions: RetentionOptions

    @OptionGroup(title: "Results")
    var resultsOptions: ResultsOptions

    @OptionGroup(title: "Baseline")
    var baselineOptions: BaselineOptions

    @OptionGroup(title: "Localized strings")
    var localizedStringOptions: LocalizedStringOptions

    @OptionGroup(title: "Miscellaneous")
    var miscellaneousOptions: MiscellaneousOptions

    @OptionGroup(visibility: .hidden)
    var removedBazelOptions: RemovedBazelOptions

    func validate() throws {
        try removedBazelOptions.rejectUse()

        if let maxResults = resultsOptions.maxResults, maxResults < 1 {
            throw ValidationError("'--max-results' must be at least 1")
        }
    }

    /// Applies the options given on the command line to a configuration that holds the values of the configuration file.
    func apply(to configuration: Configuration) {
        configuration.apply(\.$project, projectOptions.project)
        configuration.apply(\.$schemes, given(projectOptions.schemes))
        configuration.apply(\.$indexExclude, given(buildOptions.indexExclude))
        configuration.apply(\.$reportExclude, given(resultsOptions.reportExclude).map { $0.map { .pattern($0) } })
        configuration.apply(\.$reportInclude, given(resultsOptions.reportInclude))
        configuration.apply(\.$outputFormat, resultsOptions.format)
        configuration.apply(\.$retainFiles, given(retentionOptions.retainFiles))
        configuration.apply(\.$retainPublic, retentionOptions.retainPublic)
        configuration.apply(\.$retainPublicModules, given(retentionOptions.retainPublicModules) ?? (retentionOptions.retainPublic == false ? [] : nil))
        configuration.apply(\.$noRetainSPI, given(retentionOptions.noRetainSPI))
        configuration.apply(\.$retainAssignOnlyProperties, retentionOptions.retainAssignOnlyProperties)
        configuration.apply(\.$retainAssignOnlyPropertyTypes, given(retentionOptions.retainAssignOnlyPropertyTypes))
        configuration.apply(\.$enableUnassignedOptionalAnalysis, analysisOptions.enableUnassignedOptionalAnalysis)
        configuration.apply(\.$retainObjcAccessible, retentionOptions.retainObjcAccessible)
        configuration.apply(\.$retainJsAccessible, retentionOptions.retainJsAccessible)
        configuration.apply(\.$retainObjcAnnotated, retentionOptions.retainObjcAnnotated)
        configuration.apply(\.$retainUnusedProtocolFuncParams, retentionOptions.retainUnusedProtocolFuncParams)
        configuration.apply(\.$retainUnusedParametersWithoutDefault, retentionOptions.retainUnusedParametersWithoutDefault)
        configuration.apply(\.$retainSwiftUIPreviews, retentionOptions.retainSwiftUIPreviews)
        configuration.apply(\.$disableRedundantPublicAnalysis, analysisOptions.disableRedundantPublicAnalysis)
        configuration.apply(\.$enableRedundantPublicMembers, analysisOptions.enableRedundantPublicMembers)
        configuration.apply(\.$enableOpenFinalAnalysis, analysisOptions.enableOpenFinalAnalysis)
        configuration.apply(\.$enableEmptyExtensionAnalysis, analysisOptions.enableEmptyExtensionAnalysis)
        configuration.apply(\.$enableRedundantAccessLevelAnalysis, analysisOptions.enableRedundantAccessLevelAnalysis)
        configuration.apply(\.$reportUnusedTypeParameters, analysisOptions.reportUnusedTypeParameters)
        configuration.apply(\.$disablePlatformConditionalRetention, analysisOptions.disablePlatformConditionalRetention)
        configuration.apply(\.$disableUnusedImportAnalysis, analysisOptions.disableUnusedImportAnalysis)
        configuration.apply(\.$enableUnusedSystemImports, analysisOptions.enableUnusedSystemImports)
        configuration.apply(\.$superfluousIgnoreComments, analysisOptions.superfluousIgnoreComments)
        configuration.apply(\.$disableUnusedLocalizedStringAnalysis, localizedStringOptions.disableUnusedLocalizedStringAnalysis)
        configuration.apply(\.$localizedStringCatalogExclude, given(localizedStringOptions.localizedStringCatalogExclude))
        configuration.apply(\.$localizedStringKeyPatterns, given(localizedStringOptions.localizedStringKeyPatterns))
        configuration.apply(\.$localizedStringKeyLiteralMatch, localizedStringOptions.localizedStringKeyLiteralMatch)
        configuration.apply(\.$retainRuntimeLocalizedKeys, localizedStringOptions.retainRuntimeLocalizedKeys)
        configuration.apply(\.$retainUnusedImportedModules, given(retentionOptions.retainUnusedImportedModules))
        configuration.apply(\.$externalEncodableProtocols, given(retentionOptions.externalEncodableProtocols))
        configuration.apply(\.$externalCodableProtocols, given(retentionOptions.externalCodableProtocols))
        configuration.apply(\.$externalTestCaseClasses, given(retentionOptions.externalTestCaseClasses))
        configuration.apply(\.$verbose, miscellaneousOptions.verbose)
        configuration.apply(\.$quiet, miscellaneousOptions.quiet)
        configuration.apply(\.$color, miscellaneousOptions.noColor ? .never : miscellaneousOptions.color)
        configuration.apply(\.$disableUpdateCheck, miscellaneousOptions.disableUpdateCheck)
        configuration.apply(\.$strict, resultsOptions.strict)
        configuration.apply(\.$indexStorePath, given(buildOptions.indexStorePath))
        configuration.apply(\.$derivedDataPath, given(buildOptions.derivedDataPath))
        configuration.apply(\.$skipBuild, buildOptions.skipBuild)
        configuration.apply(\.$excludeTests, buildOptions.excludeTests)
        configuration.apply(\.$excludeTargets, given(buildOptions.excludeTargets))
        configuration.apply(\.$skipSchemesValidation, buildOptions.skipSchemesValidation)
        configuration.apply(\.$cleanBuild, buildOptions.cleanBuild)
        configuration.apply(\.$strictIndex, buildOptions.strictIndex)
        configuration.apply(\.$strictIndexCoverage, buildOptions.strictIndexCoverage)
        configuration.apply(\.$indexBuiltFrom, buildOptions.indexBuiltFrom)
        configuration.apply(\.$cacheMaxAgeDays, buildOptions.cacheMaxAgeDays)
        configuration.apply(\.$cacheMaxSizeGB, buildOptions.cacheMaxSizeGb)
        configuration.apply(\.$buildArguments, given(buildArguments))
        configuration.apply(\.$relativeResults, resultsOptions.relativeResults)
        configuration.apply(\.$relativeResultsBase, resultsOptions.relativeTo)
        configuration.apply(\.$changedSince, resultsOptions.changedSince)
        configuration.apply(\.$changedLines, resultsOptions.changedLines)
        configuration.apply(\.$retainCodableProperties, retentionOptions.retainCodableProperties)
        configuration.apply(\.$retainEncodableProperties, retentionOptions.retainEncodableProperties)
        configuration.apply(\.$retainEquatableProperties, retentionOptions.retainEquatableProperties)
        configuration.apply(\.$retainHashableProperties, retentionOptions.retainHashableProperties)
        configuration.apply(\.$jsonPackageManifestPath, projectOptions.jsonPackageManifestPath)
        configuration.apply(\.$baseline, baselineOptions.baseline)
        configuration.apply(\.$writeBaseline, baselineOptions.writeBaseline)
        configuration.apply(\.$pruneBaseline, baselineOptions.pruneBaseline)
        configuration.apply(\.$strictBaseline, baselineOptions.strictBaseline)
        configuration.apply(\.$writeResults, resultsOptions.writeResults)
        configuration.apply(\.$skipStdoutResults, resultsOptions.skipStdoutResults)
        configuration.apply(\.$genericProjectConfig, projectOptions.genericProjectConfig)
        configuration.apply(\.$retainSynthesizedUses, retentionOptions.retainSynthesizedUses)
        configuration.apply(\.$retainAttributes, given(retentionOptions.retainAttributes))
        configuration.apply(\.$detectUnusedAssetCatalogColors, analysisOptions.detectUnusedAssetCatalogColors)
        configuration.apply(\.$detectUnusedAssetCatalogImages, analysisOptions.detectUnusedAssetCatalogImages)
        configuration.apply(\.$detectUnusedMetalFunctions, analysisOptions.detectUnusedMetalFunctions)
    }

    /// What a command needs to run the scan: the configuration, validated, and the project to scan.
    struct PreparedScan {
        let configuration: Configuration
        let logger: Logger
        let shell: ShellImpl
        let swiftVersion: SwiftVersion
        let project: Project
        let baseline: Baseline?
    }

    /// Loads and validates the configuration, then identifies the project; nothing is built yet.
    /// - Parameter messagesToStderr: Sends progress and debug messages to stderr whatever the output format.
    func prepareScan(messagesToStderr: Bool = false) throws -> PreparedScan {
        let projectRoot = try changeToProjectRoot()
        let (configuration, configurationWarnings) = try loadConfiguration(projectRoot: projectRoot)
        let logger = Logger(configuration: configuration, messagesToStderr: messagesToStderr)
        let baseline = try validate(configuration, logger: logger)

        configurationWarnings.forEach { logger.warn($0) }
        ScanPreflight.applyOutputFormatRequirements(to: configuration, logger: logger)
        logger.contextualized(with: "version").debug(PeripheryVersion)
        let shell = makeShell(logger: logger)
        let swiftVersion = try SwiftVersion(shell: shell)
        logger.debug(swiftVersion.fullVersion)
        try swiftVersion.validateVersion()

        let project = try makeProject(configuration: configuration, shell: shell, logger: logger)
        return PreparedScan(configuration: configuration, logger: logger, shell: shell, swiftVersion: swiftVersion, project: project, baseline: baseline)
    }

    func run() throws {
        let prepared = try prepareScan()
        let configuration = prepared.configuration
        let logger = prepared.logger

        let updateChecker = UpdateChecker(logger: logger, configuration: configuration)
        updateChecker.run()

        let scanOutput = try Scan(
            configuration: configuration,
            logger: logger,
            swiftVersion: prepared.swiftVersion
        ).perform(project: prepared.project)

        let interval = logger.beginInterval("result:output")

        let outputFilter = OutputDeclarationFilter(configuration: configuration, logger: logger)
        let filteredResults = try outputFilter.filter(scanOutput.results, with: prepared.baseline)
        try writeBaselines(configuration: configuration, outputFilter: outputFilter, filteredResults: filteredResults, baseline: prepared.baseline, logger: logger)

        let reportedResults = try ChangedSinceFilter(configuration: configuration, shell: prepared.shell, logger: logger).filter(filteredResults)
        try outputResults(reportedResults, filteredResultCount: filteredResults.count, configuration: configuration, logger: logger)

        logger.endInterval(interval)

        updateChecker.notifyIfAvailable()

        try checkExitStatus(reportedResultCount: reportedResults.count, staleEntryCount: outputFilter.staleBaselineEntries.count, configuration: configuration)
    }

    private func changeToProjectRoot() throws -> FilePath {
        let projectRoot = projectOptions.projectRoot ?? FilePath(FileManager.default.currentDirectoryPath)
        if !FileManager.default.changeCurrentDirectoryPath(projectRoot.string) {
            throw PeripheryError.changeCurrentDirectoryFailed(projectRoot)
        }
        return projectRoot
    }

    private func loadConfiguration(projectRoot: FilePath) throws -> (Configuration, [String]) {
        let configuration = Configuration()
        var configurationWarnings: [String] = []

        if !projectOptions.setup {
            try configuration.load(from: projectOptions.config) { configurationWarnings.append($0) }
        }

        configuration.guidedSetup = projectOptions.setup
        configuration.explain = resultsOptions.explain
        configuration.projectRoot = projectRoot
        apply(to: configuration)
        return (configuration, configurationWarnings)
    }

    private func validate(_ configuration: Configuration, logger: Logger) throws -> Baseline? {
        if configuration.skipStdoutResults, configuration.writeResults == nil {
            throw PeripheryError.usageError("The '--skip-stdout-results' option requires '--write-results', otherwise the results would not be output anywhere.")
        }

        if configuration.changedLines, configuration.changedSince == nil {
            throw PeripheryError.usageError("The '--changed-lines' option requires '--changed-since', otherwise there is nothing to compare the lines with.")
        }

        configuration.buildFilenameMatchers(debug: logger.debug)
        _ = try ReportExcludeRule.resolve(configuration)
        _ = try AttributeRetentionRule.resolve(configuration)
        return try ScanPreflight.validatePaths(of: configuration)
    }

    private func makeShell(logger: Logger) -> ShellImpl {
        ShellImpl(logger: logger) {
            logger.warn(
                "Termination can result in a corrupt index. Try the '--clean-build' flag if you get erroneous results such as false-positives and incorrect source file locations.",
                newlinePrefix: true // Print a newline after ^C
            )
        }
    }

    private func makeProject(configuration: Configuration, shell: ShellImpl, logger: Logger) throws -> Project {
        if configuration.guidedSetup {
            try GuidedSetup(configuration: configuration, shell: shell, logger: logger).perform()
        } else {
            try Project(configuration: configuration, shell: shell, logger: logger)
        }
    }

    private func writeBaselines(configuration: Configuration, outputFilter: OutputDeclarationFilter, filteredResults: [ScanResult], baseline: Baseline?, logger: Logger) throws {
        if configuration.pruneBaseline, let baselinePath = OutputPath(configuration.baseline, option: baselineOptions.baseline) {
            try Self.writeBaseline(.pruned(keeping: outputFilter.baselineMatchedResults, projectRoot: configuration.projectRoot), to: baselinePath.path, configuredIn: baselinePath.configuredIn(configuration.projectRoot))
            logger.info("Pruned \(outputFilter.staleBaselineEntries.count) stale entries from \(baselinePath.path.string)")
        }

        if let baselinePath = OutputPath(configuration.writeBaseline, option: baselineOptions.writeBaseline) {
            try Self.writeBaseline(.written(from: filteredResults, union: baseline, projectRoot: configuration.projectRoot), to: baselinePath.path, configuredIn: baselinePath.configuredIn(configuration.projectRoot))
        }
    }

    private func outputResults(_ reportedResults: [ScanResult], filteredResultCount: Int, configuration: Configuration, logger: Logger) throws {
        let outputFormat = configuration.outputFormat
        let formatter = outputFormat.formatter.init(configuration: configuration, logger: logger)
        (formatter as? AgentFormatter)?.maxResults = resultsOptions.maxResults
        let colored = outputFormat.supportsColoredOutput && logger.isColoredOutputEnabled

        let formattedOutput = try formatter.format(reportedResults, colored: colored)

        if let output = formattedOutput, Self.shouldPrintToStdout(configuration: configuration, resultCount: filteredResultCount) {
            if outputFormat.supportsAuxiliaryOutput {
                logger.info("", canQuiet: true)
            }

            logger.output(output)
        }

        if let resultsPath = OutputPath(configuration.writeResults, option: resultsOptions.writeResults) {
            let output: String = if colored {
                // The formatted output contains ANSI escape codes, so we need to re-format
                // with coloring disabled.
                try formatter.format(reportedResults, colored: false) ?? ""
            } else {
                formattedOutput ?? ""
            }

            // A path from the configuration file is project content, which a link must not lead out of the project.
            if resultsPath.isFromConfigurationFile {
                try OutputFile.writeConfigured(Data(output.utf8), to: resultsPath.path, projectRoot: configuration.projectRoot)
            } else {
                try OutputFile.write(Data(output.utf8), to: resultsPath.path)
            }
        }
    }

    private func checkExitStatus(reportedResultCount: Int, staleEntryCount: Int, configuration: Configuration) throws {
        if reportedResultCount > 0, configuration.strict {
            throw PeripheryError.foundIssues(count: reportedResultCount)
        }

        if let failure = Self.staleBaselineFailure(configuration: configuration, staleEntryCount: staleEntryCount) {
            throw failure
        }
    }

    /// With `--quiet`, stdout stays empty when there is nothing to report, and the report goes to
    /// the `--write-results` file only.
    static func shouldPrintToStdout(configuration: Configuration, resultCount: Int) -> Bool {
        if configuration.skipStdoutResults {
            return false
        }
        if configuration.quiet, configuration.writeResults != nil || resultCount == 0 {
            return false
        }
        return true
    }

    /// The error that ends the scan with a non-zero status when `--strict-baseline` finds stale entries; none when
    /// `--prune-baseline` has just removed them.
    static func staleBaselineFailure(configuration: Configuration, staleEntryCount: Int) -> PeripheryError? {
        guard configuration.strictBaseline, !configuration.pruneBaseline, staleEntryCount > 0 else { return nil }

        return .staleBaselineEntries(count: staleEntryCount)
    }

    static func writeBaseline(_ baseline: Baseline, to path: FilePath, configuredIn projectRoot: FilePath? = nil) throws {
        try baseline.write(to: path, configuredIn: projectRoot)
    }

    // MARK: - Private

    /// An output path with its origin: the command line, or the configuration file when the option was not passed.
    private struct OutputPath {
        let path: FilePath
        let isFromConfigurationFile: Bool

        init?(_ path: FilePath?, option: FilePath?) {
            guard let path else { return nil }

            self.path = path
            isFromConfigurationFile = option == nil
        }

        /// The project root a path from the configuration file must stay in, nil for a command line path.
        func configuredIn(_ projectRoot: FilePath) -> FilePath? {
            isFromConfigurationFile ? projectRoot : nil
        }
    }

    /// The values of a list option, or nil when the option was not passed: ArgumentParser reports an option that is not passed as an empty list.
    private func given<T>(_ values: [T]) -> [T]? {
        values.isEmpty ? nil : values
    }
}

extension OutputFormat: ArgumentParser.ExpressibleByArgument {}
extension ColorOption: ArgumentParser.ExpressibleByArgument {}

extension FilePath: ArgumentParser.ExpressibleByArgument {
    public init?(argument: String) {
        self.init(argument)
    }
}
