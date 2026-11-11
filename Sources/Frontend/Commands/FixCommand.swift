import ArgumentParser
import Configuration
import FilenameMatcher
import Fix
import Foundation
import Logger
import PeripheryKit
import Shared
import SourceGraph
import SystemPackage

struct FixCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fix",
        abstract: "Scan, then remove the unused String Catalog keys: print a unified diff, or write the catalogs with --apply",
        usage: "outskirts fix [<options>] [-- <build-arguments> ...]",
        discussion: """
        Takes every option of the scan command and removes exactly the unused localized string keys that the scan reports, \
        after the baseline, report_exclude, report_include and the comment commands. Only the catalogs that git tracks without \
        uncommitted changes are written, unless '--allow-dirty' is given. A key used only by code that the scan leaves out \
        would be removed, so a partial scan and keys built at runtime are refused.
        """
    )

    @OptionGroup(title: "Fix")
    var fixOptions: FixOptions

    @OptionGroup
    var scan: ScanCommand

    func validate() throws {
        if scan.projectOptions.setup {
            throw ValidationError("'--setup' cannot be used with 'fix', run 'scan --setup' first")
        }
        if scan.baselineOptions.writeBaseline != nil || scan.baselineOptions.pruneBaseline == true {
            throw ValidationError("'fix' does not write baselines, run 'scan' for '--write-baseline' and '--prune-baseline'")
        }
        if scan.resultsOptions.writeResults != nil {
            throw ValidationError("'fix' does not write results, run 'scan' for '--write-results'")
        }
    }

    func run() throws {
        let prepared = try scan.prepareScan(messagesToStderr: true)
        let configuration = prepared.configuration
        let logger = prepared.logger
        try Self.validateScope(of: configuration, projectKind: prepared.project.kind, allowPartialScan: fixOptions.allowPartialScan)

        // Recorded before the scan reads any catalog: a catalog modified since may not match the results.
        let scanStartedAt = Date()
        let output = try Scan(configuration: configuration, logger: logger, swiftVersion: prepared.swiftVersion)
            .perform(project: prepared.project)
        let filtered = try OutputDeclarationFilter(configuration: configuration, logger: logger)
            .filter(output.results, with: prepared.baseline)
        let reported = try ChangedSinceFilter(configuration: configuration, shell: prepared.shell, logger: logger)
            .filter(filtered)

        let includeMatchers = configuration.buildFilenameMatchers(with: fixOptions.includes)
        let keysByCatalog = FixPlanner.unusedCatalogKeys(in: reported).filter { catalog, _ in
            includeMatchers.isEmpty || includeMatchers.anyMatch(filename: catalog.string)
        }
        let runtimeKeysRefusal = Self.runtimeKeysRefusal(output.unprefixedRuntimeLocalizedStringKeyLocations, configuration: configuration)
        if let runtimeKeysRefusal, !keysByCatalog.isEmpty, !fixOptions.allowRuntimeKeys {
            if fixOptions.apply {
                throw PeripheryError.usageError(runtimeKeysRefusal)
            }
            logger.warn(runtimeKeysRefusal)
        }

        let root = FilePath.current
        let workingTree: WorkingTreeState = try fixOptions.allowDirty ? .ignored : GitWorkingTree.state(at: root)
        let plan = FixPlanner(projectRoot: root, workingTree: workingTree, scanStartedAt: scanStartedAt).plan(keysByCatalog)

        if fixOptions.apply {
            try FixWriter.apply(plan)
        } else {
            let diff = plan.diff(relativeTo: root)
            if !diff.isEmpty {
                logger.output(String(diff.dropLast()))
            }
        }
        logger.info(plan.summary(relativeTo: root, applying: fixOptions.apply))
    }

    /// Refuses a scan that cannot tell which keys are unused: a key is only unused if every code that may use it was
    /// scanned.
    static func validateScope(of configuration: Configuration, projectKind: ProjectKind, allowPartialScan: Bool) throws {
        if configuration.disableUnusedLocalizedStringAnalysis {
            throw PeripheryError.usageError("'fix' removes the unused String Catalog keys, but the unused localized string analysis is disabled (disable_unused_localized_string_analysis). Enable it to fix the catalogs.")
        }
        if !allowPartialScan, let partialScan = PartialScan(of: projectKind, configuration: configuration) {
            throw PeripheryError.usageError(partialScan.refusal)
        }
    }

    /// Why `--apply` is refused when keys built at runtime without a literal prefix may look up any key, unless
    /// `localized_string_key_patterns` declares them or `retain_runtime_localized_keys` retains them all; nil otherwise.
    static func runtimeKeysRefusal(_ locations: Set<Location>, configuration: Configuration) -> String? {
        guard !locations.isEmpty, !configuration.retainRuntimeLocalizedKeys, configuration.localizedStringKeyPatterns.isEmpty else { return nil }

        let sites = locations.sorted().map { "  \($0)" }.joined(separator: "\n")
        return """
        Localized string keys are built at runtime without a literal prefix, so the keys they look up cannot be known, and '--apply' could remove keys in use:
        \(sites)
        Declare the keys they build with localized_string_key_patterns, set retain_runtime_localized_keys, or pass '--allow-runtime-keys' once you have checked the removed keys.
        """
    }
}

struct FixOptions: ParsableArguments {
    @Flag(help: "Write the changes, to every catalog or to none, instead of printing a unified diff")
    var apply: Bool = false

    @Option(name: .customLong("include"), help: ArgumentHelp("Only fix the String Catalogs that match the glob; repeat to give several", valueName: "glob"))
    var includes: [String] = []

    @Flag(help: "Also fix catalogs that have uncommitted changes, or that are not in a git repository")
    var allowDirty: Bool = false

    @Flag(help: "Fix after a scan that leaves code out: an Xcode project (only the listed schemes are built, in the Debug configuration), index_exclude, exclude_tests or exclude_targets. A key used only by the code left out is removed")
    var allowPartialScan: Bool = false

    @Flag(help: "Apply although localized string keys built at runtime without a literal prefix may look up the removed keys")
    var allowRuntimeKeys: Bool = false
}

extension FixCommand {
    /// Why a scan may leave out code that uses a String Catalog key.
    enum PartialScan: Equatable {
        case xcodeProject
        /// An option that leaves code out of the index.
        case narrowing(String)

        init?(of projectKind: ProjectKind, configuration: Configuration) {
            if case .xcode = projectKind {
                self = .xcodeProject
            } else if let narrowing = Self.narrowingOption(of: configuration) {
                self = .narrowing(narrowing)
            } else {
                return nil
            }
        }

        var refusal: String {
            let message = switch self {
            case .xcodeProject:
                "'fix' removes the String Catalog keys that no scanned code uses, but an Xcode project is only built for the listed schemes, in the Debug configuration: a key used only by a target outside these schemes, or by code that another configuration compiles, would be removed. List every scheme that builds code using the catalogs in '--schemes'."
            case let .narrowing(option):
                "'fix' removes the String Catalog keys that no scanned code uses, but '\(option)' leaves code out of the scan: a key used only there would be removed. Remove '\(option)'."
            }
            return message + " Pass '--allow-partial-scan' to accept this."
        }

        /// The first option that leaves code out of the index. `report_exclude` and `report_include` only narrow the
        /// results, so the uses stay.
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
