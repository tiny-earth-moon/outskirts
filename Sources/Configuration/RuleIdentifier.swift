/// The rules outskirts checks, under the ids shared by the configuration v2 (`rules`) and the output v2.
public enum RuleIdentifier: String, CaseIterable, Codable, CodingKeyRepresentable, Sendable {
    case unused
    case unusedImport = "unused-import"
    case unusedParameter = "unused-parameter"
    case unusedLocalizedString = "unused-localized-string"
    case unusedAssetColor = "unused-asset-color"
    case unusedAssetImage = "unused-asset-image"
    case assignOnlyProperty = "assign-only-property"
    case unassignedOptional = "unassigned-optional"
    case redundantProtocol = "redundant-protocol"
    case redundantConformance = "redundant-conformance"
    case redundantPublic = "redundant-public"
    case redundantOpen = "redundant-open"
    case missingFinal = "missing-final"
    case redundantAccessLevel = "redundant-access-level"
    case emptyExtension = "empty-extension"
    case superfluousIgnore = "superfluous-ignore"

    /// Whether the rule is checked when the configuration does not mention it.
    public var isEnabledByDefault: Bool {
        switch self {
        case .unused, .unusedImport, .unusedParameter, .unusedLocalizedString, .assignOnlyProperty, .redundantProtocol,
             .redundantConformance, .redundantPublic, .superfluousIgnore:
            true
        case .unusedAssetColor, .unusedAssetImage, .unassignedOptional, .redundantOpen, .missingFinal,
             .redundantAccessLevel, .emptyExtension:
            false
        }
    }

    /// The v1 key that turns the rule on or off, nil for a rule that is always checked. `redundant-open` and
    /// `missing-final` share `enable_open_final_analysis`.
    public var v1Key: String? {
        switch self {
        case .unused, .unusedParameter, .redundantProtocol, .redundantConformance:
            nil
        case .unusedImport:
            "disable_unused_import_analysis"
        case .unusedLocalizedString:
            "disable_unused_localized_string_analysis"
        case .unusedAssetColor:
            "detect_unused_asset_catalog_colors"
        case .unusedAssetImage:
            "detect_unused_asset_catalog_images"
        case .assignOnlyProperty:
            "retain_assign_only_properties"
        case .unassignedOptional:
            "enable_unassigned_optional_analysis"
        case .redundantPublic:
            "disable_redundant_public_analysis"
        case .redundantOpen, .missingFinal:
            "enable_open_final_analysis"
        case .redundantAccessLevel:
            "enable_redundant_access_level_analysis"
        case .emptyExtension:
            "enable_empty_extension_analysis"
        case .superfluousIgnore:
            "superfluous_ignore_comments"
        }
    }

    /// Whether `true` for `v1Key` turns the rule off rather than on, e.g. `disable_unused_import_analysis`.
    public var v1KeyTurnsRuleOff: Bool {
        switch self {
        case .unusedImport, .unusedLocalizedString, .assignOnlyProperty, .redundantPublic:
            true
        default:
            false
        }
    }

    /// The value of `v1Key` that gives the rule the given state.
    func v1Value(enabled: Bool) -> Bool {
        enabled != v1KeyTurnsRuleOff
    }
}

public extension Configuration {
    /// Whether the rule is checked with this configuration.
    func isEnabled(_ rule: RuleIdentifier) -> Bool {
        guard let key = rule.v1Key else { return true }
        guard let value = settings.first(where: { $0.key == key })?.wrappedValue as? Bool else {
            preconditionFailure("The v1 key '\(key)' of the rule '\(rule.rawValue)' is not a boolean setting")
        }

        return value == rule.v1Value(enabled: true)
    }
}
