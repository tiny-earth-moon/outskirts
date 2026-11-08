import ArgumentParser
import Configuration
import Fix
import Foundation
import Logger
import PeripheryKit
import ProjectDrivers
import Shared
import SystemPackage

struct FixCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fix",
        abstract: "Scan, then apply the syntax-only fixes: print a unified diff, or write the files with --apply",
        discussion: "Takes every option of the scan command. Rules: \(FixRule.allCases.filter { !$0.isAggressive && !$0.isOptIn }.map(\.rawValue).joined(separator: ", ")); with --aggressive: \(FixRule.allCases.filter(\.isAggressive).map(\.rawValue).joined(separator: ", ")); only when named with --rule: \(FixRule.allCases.filter(\.isOptIn).map(\.rawValue).joined(separator: ", ")), which requires a scan of every variant. Rules whose analysis is opt-in only apply when the analysis is enabled."
    )

    @Flag(help: "Write the fixes to the files atomically instead of printing a unified diff")
    var apply: Bool = false

    @Flag(help: "With --apply, rebuild the project after writing the fixes, and restore every original file if the build fails")
    var verify: Bool = false

    @Flag(help: "Also apply the tier-2 rules, which change behavior: add final to the classes that the open/final analysis reports")
    var aggressive: Bool = false

    @Option(name: .customLong("rule"), help: "Only apply the given rule; repeat to apply several")
    var rules: [FixRule] = []

    @Option(name: .customLong("include"), help: "Only fix the files that match the glob; repeat to give several")
    var includes: [String] = []

    @Flag(help: "Also fix files that have uncommitted changes, or that are not in a git repository")
    var allowDirty: Bool = false

    @Flag(help: "Allow '--rule unused' after a scan that did not cover every variant ('variants: default', or a variant that could not be built)")
    var allowPartialVariants: Bool = false

    @Flag(help: "Allow '--rule unused' on an Xcode project, whose scan only builds the listed schemes in Debug, or when index_exclude, exclude_tests or exclude_targets leaves code out of the scan")
    var allowPartialScan: Bool = false

    @Flag(help: "With '--rule unused', also remove public and open declarations, unless retain_public or retain_public_modules applies")
    var includePublic: Bool = false

    @OptionGroup
    var scan: ScanCommand

    func validate() throws {
        if scan.projectOptions.setup {
            throw ValidationError("'--setup' cannot be used with 'fix'")
        }
        if scan.baselineOptions.writeBaseline != nil || scan.baselineOptions.pruneBaseline == true {
            throw ValidationError("'fix' does not write baselines, run 'scan' for '--write-baseline' and '--prune-baseline'")
        }
        if scan.resultsOptions.writeResults != nil {
            throw ValidationError("'fix' does not write results, run 'scan' for '--write-results'")
        }
        if verify, !apply {
            throw ValidationError("'--verify' rebuilds the project after writing the fixes, it requires '--apply'")
        }
        if !aggressive, let rule = rules.first(where: \.isAggressive) {
            throw ValidationError("'\(rule.rawValue)' is a tier-2 rule, it requires '--aggressive'")
        }
        if allowPartialVariants, !removesUnused {
            throw ValidationError("'--allow-partial-variants' only applies to '--rule unused'")
        }
        if allowPartialScan, !removesUnused {
            throw ValidationError("'--allow-partial-scan' only applies to '--rule unused'")
        }
        if includePublic, !removesUnused {
            throw ValidationError("'--include-public' only applies to '--rule unused'")
        }
    }

    func run() throws {
        let prepared = try scan.prepareScan(messagesToStderr: true)
        let configuration = prepared.configuration
        let logger = prepared.logger
        if verify {
            try validateVerifiableBuild(configuration: configuration, project: prepared.project)
        }
        if removesUnused, !allowPartialVariants, configuration.variants == .default {
            throw PeripheryError.usageError("'--rule unused' removes declarations, which is only safe once every variant that ships is scanned: code used only in another platform's '#if' clauses would break. Set 'variants' to 'auto' or to a list of variants, or pass '--allow-partial-variants'.")
        }
        if removesUnused, !allowPartialScan, let refusal = Self.partialScanRefusal(of: prepared.project.kind, configuration: configuration) {
            throw PeripheryError.usageError(refusal)
        }

        let scanStartedAt = Date()
        let output = try Scan(configuration: configuration, logger: logger, swiftVersion: prepared.swiftVersion)
            .perform(project: prepared.project)
        let filtered = try OutputDeclarationFilter(configuration: configuration, logger: logger)
            .filter(output.results, with: prepared.baseline)
        let reported = try ChangedSinceFilter(configuration: configuration, shell: prepared.shell, logger: logger)
            .filter(filtered)

        let targets = selectTargets(from: reported, configuration: configuration)
        let workingTree: WorkingTreeState = try allowDirty ? .ignored : GitWorkingTree.state(at: configuration.projectRoot)
        let indexDates = IndexDates(scanStartedAt: scanStartedAt, unitDates: output.unitDates)
        let planner = FixPlanner(workingTree: workingTree, indexDates: indexDates, isIndexExcluded: configuration.isIndexExcluded)
        var plan = planner.plan(targets)
        if removesUnused {
            try validateVariantCoverage(of: output.driver)
            let included = reported.filter { isIncluded($0.resultDeclaration.location.file.path, configuration: configuration) }
            var removal = try UnusedRemovalSet(
                results: included,
                graph: output.graph,
                configuration: configuration,
                uncoveredNames: UncoveredConditionalNames(graph: output.graph),
                includesPublic: includePublic
            )
            plan = planner.plan(targets, removing: &removal)
        }

        if apply {
            try FixWriter.apply(plan)
        } else {
            let diff = plan.diff(relativeTo: configuration.projectRoot)
            if !diff.isEmpty {
                logger.output(String(diff.dropLast()))
            }
        }

        logger.info(plan.summary(relativeTo: configuration.projectRoot, applying: apply))
        if verify, !plan.changes.isEmpty {
            try verifyBuild(of: plan, driver: output.driver, configuration: configuration, logger: logger)
        }
    }

    // MARK: - Private

    private var removesUnused: Bool {
        rules.contains(.unused)
    }

    /// Why the scan of the project may leave out code that uses the declarations `--rule unused` would remove, or nil.
    static func partialScanRefusal(of projectKind: ProjectKind, configuration: Configuration) -> String? {
        if case .xcode = projectKind {
            return "'--rule unused' removes declarations, which is only safe when every build that compiles them is scanned, but an Xcode project is only built for the listed schemes in the Debug configuration: targets outside the schemes, other configurations and per-configuration settings such as EXCLUDED_SOURCE_FILE_NAMES are not scanned, so code only they compile could be removed. Pass '--allow-partial-scan' to accept this."
        }
        if let option = narrowingOption(of: configuration) {
            return "'--rule unused' removes declarations, which is only safe when every file that may use them is scanned, but '\(option)' leaves code out of the scan: its references would be lost. Remove '\(option)', or pass '--allow-partial-scan'."
        }
        return nil
    }

    /// The first option that leaves code out of the index, whose references to the removed declarations would be
    /// lost. `report_exclude` and `report_include` only narrow the results, so the references stay.
    private static func narrowingOption(of configuration: Configuration) -> String? {
        if !Set(configuration.indexExclude).subtracting(configuration.$indexExclude.defaultValue).isEmpty {
            return "index_exclude"
        }
        if configuration.excludeTests {
            return "exclude_tests"
        }
        if !configuration.excludeTargets.isEmpty {
            return "exclude_targets"
        }
        return nil
    }

    /// The removals are only safe when the index holds every variant the configuration declares.
    private func validateVariantCoverage(of driver: ProjectDriver) throws {
        guard !allowPartialVariants else { return }

        if !driver.skippedVariants.isEmpty {
            throw PeripheryError.usageError("'--rule unused' needs a scan of every variant, but some were not built:\n\(driver.skippedVariants.joined(separator: "\n"))\nInstall the missing SDKs, or pass '--allow-partial-variants'.")
        }
        if driver.builtVariants.isEmpty {
            throw PeripheryError.usageError("'--rule unused' needs a scan of every variant, but this scan did not build its variants ('--skip-build', '--index-store-path' or a generic project). Let outskirts build the variants, or pass '--allow-partial-variants'.")
        }
    }

    private func isIncluded(_ file: FilePath, configuration: Configuration) -> Bool {
        let includeMatchers = configuration.buildFilenameMatchers(with: includes)
        return includeMatchers.isEmpty || includeMatchers.anyMatch(filename: file.string)
    }

    /// `--verify` rebuilds with the driver of the scan, so the scan must build the project itself.
    private func validateVerifiableBuild(configuration: Configuration, project: Project) throws {
        if configuration.skipBuild || !configuration.indexStorePath.isEmpty {
            throw PeripheryError.usageError("'--verify' rebuilds the project after writing the fixes, but the build is skipped ('--skip-build' or '--index-store-path'), so the fixes could not be verified. Remove these options, or apply without '--verify' and build yourself.")
        }
        if case .generic = project.kind {
            throw PeripheryError.usageError("'--verify' rebuilds the project after writing the fixes, but a project described by '--generic-project-config' is built outside outskirts, so the fixes could not be verified. Apply without '--verify' and build yourself.")
        }
    }

    /// Rebuilds the project; when the build fails, writes back every original buffer and fails.
    private func verifyBuild(of plan: FixPlan, driver: ProjectDriver, configuration: Configuration, logger: Logger) throws {
        // The scan already cleaned the build if asked to: only the fixed files need to be rebuilt.
        configuration.cleanBuild = false
        do {
            try driver.build()
        } catch {
            let restoration = FixWriter.restore(plan)
            logger.error("The build failed after the fixes were applied:\n\(error.localizedDescription)")
            throw PeripheryError.buildFailed(message: restoration.summary(relativeTo: configuration.projectRoot, changeCount: plan.changes.count))
        }
        logger.info("The project builds with the fixes.")
    }

    private func selectTargets(from results: [ScanResult], configuration: Configuration) -> [FixTarget] {
        let selectedRules = rules.isEmpty ? Set(FixRule.allCases.filter { (aggressive || !$0.isAggressive) && !$0.isOptIn }) : Set(rules)
        let includeMatchers = configuration.buildFilenameMatchers(with: includes)

        // Unused declarations are removed as a set, after the eligibility rules.
        return results.compactMap(FixTarget.init(result:)).filter { target in
            target.rule != .unused
                && selectedRules.contains(target.rule)
                && target.rule.isEnabled(in: configuration)
                && (includeMatchers.isEmpty || includeMatchers.anyMatch(filename: target.file.string))
        }
    }
}

extension FixRule: ExpressibleByArgument {}
