import Configuration

/// A kind of result that `outskirts fix` applies with a syntax-only edit. Tier-1 rules apply by default, tier-2 rules
/// only with `--aggressive`, and opt-in rules only when `--rule` names them.
public enum FixRule: String, CaseIterable, Sendable {
    case redundantPublic = "redundant-public"
    case redundantOpen = "redundant-open"
    case redundantAccessLevel = "redundant-access-level"
    case emptyExtension = "empty-extension"
    case unusedImport = "unused-import"
    case superfluousIgnore = "superfluous-ignore"
    case unusedParameter = "unused-parameter"
    case missingFinal = "missing-final"

    /// Whether the rule only applies when `--rule` names it: a redundant `public` may be the API of the project, which
    /// clients outside the scan use.
    public var isOptIn: Bool {
        self == .redundantPublic
    }

    /// Whether the rule is a tier-2 rule, which changes behavior and only applies with `--aggressive`.
    public var isAggressive: Bool {
        self == .missingFinal
    }

    /// Whether the rule takes away something that code the scan did not compile may use: an access level, the ability
    /// to subclass or override, or an import. Such code includes the `#if` clauses that no scanned build compiled.
    var isRestrictive: Bool {
        switch self {
        case .redundantPublic, .redundantOpen, .unusedImport, .missingFinal:
            true
        case .redundantAccessLevel, .emptyExtension, .superfluousIgnore, .unusedParameter:
            false
        }
    }

    /// Whether the rule is only safe after a scan that covers all the code: every variant, built by this run, and no
    /// option that leaves code out of the index. A rule that changes what other files may do needs it; an unused
    /// import is decided from its own file, whose uncompiled clauses the guards of `fix` read.
    public var requiresCompleteScan: Bool {
        isRestrictive && self != .unusedImport
    }

    /// Whether the analysis that produces the results of this rule is enabled. Opt-in analyses are only fixed when
    /// they are enabled on the command line or in the configuration file.
    public func isEnabled(in configuration: Configuration) -> Bool {
        switch self {
        case .redundantPublic:
            !configuration.disableRedundantPublicAnalysis
        case .redundantOpen:
            configuration.enableOpenFinalAnalysis
        case .redundantAccessLevel:
            configuration.enableRedundantAccessLevelAnalysis
        case .emptyExtension:
            configuration.enableEmptyExtensionAnalysis
        case .unusedImport:
            !configuration.disableUnusedImportAnalysis
        case .superfluousIgnore:
            configuration.superfluousIgnoreComments
        case .unusedParameter:
            true
        case .missingFinal:
            configuration.enableOpenFinalAnalysis
        }
    }
}
