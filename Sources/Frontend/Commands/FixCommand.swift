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
        discussion: "Takes every option of the scan command. Rules: \(FixRule.allCases.filter { !$0.isAggressive }.map(\.rawValue).joined(separator: ", ")); with --aggressive: \(FixRule.allCases.filter(\.isAggressive).map(\.rawValue).joined(separator: ", ")). Rules whose analysis is opt-in only apply when the analysis is enabled."
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

    @Flag(help: "Apply \(FixRule.allCases.filter(\.requiresCompleteScan).map(\.rawValue).joined(separator: ", ")) after a scan that did not cover all the code: 'variants: default', a variant that was not built, an Xcode project (only the listed schemes in Debug), or index_exclude, exclude_tests or exclude_targets")
    var allowPartialScan: Bool = false

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
        if allowPartialScan, !rules.isEmpty, completeScanRule == nil {
            throw ValidationError("'--allow-partial-scan' only applies to \(FixRule.allCases.filter(\.requiresCompleteScan).map { "'\($0.rawValue)'" }.joined(separator: ", "))")
        }
    }

    func run() throws {
        let prepared = try scan.prepareScan(messagesToStderr: true)
        let configuration = prepared.configuration
        let logger = prepared.logger
        if verify {
            try validateVerifiableBuild(configuration: configuration, project: prepared.project)
        }
        var partialScan = allowPartialScan ? nil : PartialScan(of: prepared.project.kind, configuration: configuration)
        if let rule = completeScanRule, let partialScan {
            throw PeripheryError.usageError(partialScan.refusal(for: rule))
        }

        let scanStartedAt = Date()
        let output = try Scan(configuration: configuration, logger: logger, swiftVersion: prepared.swiftVersion)
            .perform(project: prepared.project)
        let filtered = try OutputDeclarationFilter(configuration: configuration, logger: logger)
            .filter(output.results, with: prepared.baseline)
        let reported = try ChangedSinceFilter(configuration: configuration, shell: prepared.shell, logger: logger)
            .filter(filtered)
        if !allowPartialScan, partialScan == nil {
            partialScan = PartialScan(variantsOf: output.driver)
        }
        if let rule = completeScanRule, let partialScan {
            throw PeripheryError.usageError(partialScan.refusal(for: rule))
        }

        var guarded = selectTargets(from: reported, configuration: configuration)
        if let partialScan {
            guarded.keepRulesRequiringACompleteScan(because: partialScan.reason)
        }
        try guarded.keepUncoveredConditionalUses(in: output.graph)
        let workingTree: WorkingTreeState = try allowDirty ? .ignored : GitWorkingTree.state(at: configuration.projectRoot)
        let indexDates = IndexDates(scanStartedAt: scanStartedAt, unitDates: output.unitDates)
        let planner = FixPlanner(workingTree: workingTree, indexDates: indexDates, isIndexExcluded: configuration.isIndexExcluded)
        var plan = planner.plan(guarded.targets)
        plan.addSkipped(guarded)

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

    /// The first rule given with `--rule` that needs a scan of all the code.
    private var completeScanRule: FixRule? {
        rules.first(where: \.requiresCompleteScan)
    }

    /// Why the scan of the project may leave out code that the rule needs to see, or nil.
    static func partialScanRefusal(for rule: FixRule, of projectKind: ProjectKind, configuration: Configuration) -> String? {
        PartialScan(of: projectKind, configuration: configuration)?.refusal(for: rule)
    }

    /// The rule is only safe when the index holds every variant the configuration declares, built by this run.
    static func validateVariantCoverage(of driver: ProjectDriver, for rule: FixRule) throws {
        if let partialScan = PartialScan(variantsOf: driver) {
            throw PeripheryError.usageError(partialScan.refusal(for: rule))
        }
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

    /// Rebuilds the project; when the build fails, writes back every original buffer of the plan and fails.
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

    private func selectTargets(from results: [ScanResult], configuration: Configuration) -> GuardedTargets {
        let selectedRules = rules.isEmpty ? Set(FixRule.allCases.filter { aggressive || !$0.isAggressive }) : Set(rules)
        let includeMatchers = configuration.buildFilenameMatchers(with: includes)

        return GuardedTargets(results) { target in
            selectedRules.contains(target.rule)
                && target.rule.isEnabled(in: configuration)
                && (includeMatchers.isEmpty || includeMatchers.anyMatch(filename: target.file.string))
        }
    }
}

extension FixCommand {
    /// Why a scan may leave out code that a rule requiring a complete scan needs to see.
    enum PartialScan {
        case defaultVariants
        case xcodeProject
        /// An option that leaves code out of the index, whose references would be lost.
        case narrowing(String)
        case skippedVariants([String])
        case variantsNotBuilt

        /// Why the scan may be partial before it runs, from the project and the configuration, or nil.
        init?(of projectKind: ProjectKind, configuration: Configuration) {
            if configuration.variants == .default {
                self = .defaultVariants
            } else if case .xcode = projectKind {
                self = .xcodeProject
            } else if let narrowing = Self.narrowingOption(of: configuration) {
                self = .narrowing(narrowing)
            } else {
                return nil
            }
        }

        /// Why the scan was partial once it ran: the index must hold every variant the configuration declares, built
        /// by this run.
        init?(variantsOf driver: ProjectDriver) {
            if !driver.skippedVariants.isEmpty {
                self = .skippedVariants(driver.skippedVariants)
            } else if driver.builtVariants.isEmpty {
                self = .variantsNotBuilt
            } else {
                return nil
            }
        }

        /// The usage error of a rule named with `--rule`.
        func refusal(for rule: FixRule) -> String {
            let option = "'--rule \(rule.rawValue)'"
            let message = switch self {
            case .defaultVariants:
                "\(option) is only safe once every variant that ships is scanned: code used only in another platform's '#if' clauses would be missed. Set 'variants' to 'auto' or to a list of variants."
            case .xcodeProject:
                "\(option) is only safe when every build that compiles the code is scanned, but an Xcode project is only built for the listed schemes in the Debug configuration: targets outside the schemes, other configurations and per-configuration settings such as EXCLUDED_SOURCE_FILE_NAMES are not scanned."
            case let .narrowing(narrowing):
                "\(option) is only safe when every file that may use the code it changes is scanned, but '\(narrowing)' leaves code out of the scan: its references would be lost. Remove '\(narrowing)'."
            case let .skippedVariants(skipped):
                "\(option) needs a scan of every variant, but some were not built:\n\(skipped.joined(separator: "\n"))\nInstall the missing SDKs."
            case .variantsNotBuilt:
                "\(option) needs a scan of every variant, but this scan did not build its variants ('--skip-build', '--index-store-path' or a generic project). Let outskirts build the variants."
            }
            return message + " Pass '--allow-partial-scan' to accept this."
        }

        /// The short reason of the targets skipped when the rule was not named with `--rule`.
        var reason: String {
            switch self {
            case .defaultVariants: "'variants' is 'default'"
            case .xcodeProject: "Xcode project, only the listed schemes in Debug are built"
            case let .narrowing(narrowing): "'\(narrowing)' leaves code out of the scan"
            case .skippedVariants: "some variants were not built"
            case .variantsNotBuilt: "the variants were not built by this run"
            }
        }

        /// The first option that leaves code out of the index, whose references would be lost. `report_exclude` and
        /// `report_include` only narrow the results, so the references stay.
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
    }
}

extension FixRule: ExpressibleByArgument {}
