import FilenameMatcher
import Foundation
import SystemPackage

/// An entry of `overrides` in a configuration v2 file: settings that apply to the declarations of the modules and
/// files it matches instead of the top-level ones.
public struct ConfigurationOverride {
    /// The rules an override can turn off: their results are dropped per declaration, without changing what the
    /// analysis retains.
    static let overridableRules: Set<RuleIdentifier> = [
        .unusedImport, .unusedParameter, .unassignedOptional, .redundantPublic, .redundantOpen, .missingFinal,
        .redundantAccessLevel, .emptyExtension, .superfluousIgnore,
    ]

    /// Target name globs, one of which a module of the declaration must match; empty for any module.
    let modules: [String]
    /// Absolute path globs, one of which the file of the declaration must match; empty for any file.
    let paths: [String]
    let retainPublic: Bool?
    let retainAll: Bool?
    let rules: [RuleIdentifier: Bool]

    private let moduleMatchers: [FilenameMatcher]
    private let pathMatchers: [FilenameMatcher]

    init(modules: [String], paths: [String], retainPublic: Bool?, retainAll: Bool?, rules: [RuleIdentifier: Bool]) {
        self.modules = modules
        self.paths = paths
        self.retainPublic = retainPublic
        self.retainAll = retainAll
        self.rules = rules
        moduleMatchers = modules.map { FilenameMatcher(pattern: $0, options: [.caseSensitive]) }
        pathMatchers = paths.map { FilenameMatcher(relativePattern: $0, to: "/", caseSensitive: false) }
    }

    func matches(modules declarationModules: Set<String>, path: FilePath) -> Bool {
        (moduleMatchers.isEmpty || declarationModules.contains { moduleMatchers.anyMatch(filename: $0) })
            && (pathMatchers.isEmpty || pathMatchers.anyMatch(filename: path.string))
    }
}

/// The settings that apply to one declaration: the top-level ones, changed by the overrides that match it, the last
/// matching override winning for each setting.
public struct DeclarationSettings {
    /// The setting that retains the public declarations, `retain_public`, `retain_public_modules` or `overrides`; nil
    /// when they are not retained.
    public let publicRetentionKey: String?
    /// Whether every declaration is retained, by `overrides` (`retain.all`).
    public let retainsAll: Bool
    private let disabledRules: Set<RuleIdentifier>

    public var retainsPublic: Bool {
        publicRetentionKey != nil
    }

    init(publicRetentionKey: String?, retainsAll: Bool, disabledRules: Set<RuleIdentifier>) {
        self.publicRetentionKey = publicRetentionKey
        self.retainsAll = retainsAll
        self.disabledRules = disabledRules
    }

    /// Whether the results of the rule are reported for the declaration. A rule that is off at the top level is not
    /// checked at all, overrides only turn rules off.
    public func isEnabled(_ rule: RuleIdentifier) -> Bool {
        !disabledRules.contains(rule)
    }
}

public extension Configuration {
    /// The settings that apply to a declaration of a file compiled into the given modules.
    func settings(forModules modules: Set<String>, path: FilePath) -> DeclarationSettings {
        var publicRetentionKey: String? = if retainPublic {
            "retain_public"
        } else if retainPublicModules.contains(where: modules.contains) {
            "retain_public_modules"
        } else {
            nil
        }
        var retainsAll = false
        var disabledRules = Set<RuleIdentifier>()

        for override in overrides where override.matches(modules: modules, path: path) {
            if let retainPublic = override.retainPublic {
                publicRetentionKey = retainPublic ? "overrides" : nil
            }
            if let retainAll = override.retainAll {
                retainsAll = retainAll
            }
            for (rule, isOn) in override.rules {
                if isOn {
                    disabledRules.remove(rule)
                } else {
                    disabledRules.insert(rule)
                }
            }
        }

        return DeclarationSettings(publicRetentionKey: publicRetentionKey, retainsAll: retainsAll, disabledRules: disabledRules)
    }

    /// Whether every public declaration is retained, which no override narrows.
    var retainsEveryPublicDeclaration: Bool {
        retainPublic && !overrides.contains { $0.retainPublic == false }
    }
}
