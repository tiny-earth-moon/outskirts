import Configuration
import SourceGraph

extension ScanResult {
    /// The rule of the result when `overrides` can turn it off, nil otherwise.
    var overridableRule: RuleIdentifier? {
        switch annotation {
        case .unused:
            switch declaration.kind {
            case .module:
                .unusedImport
            case .varParameter:
                .unusedParameter
            default:
                nil
            }
        case .unassignedOptionalProperty:
            .unassignedOptional
        case .redundantPublicAccessibility:
            .redundantPublic
        case .redundantOpenAccessibility:
            .redundantOpen
        case .missingFinal:
            .missingFinal
        case .redundantAccessLevel:
            .redundantAccessLevel
        case .emptyExtension:
            .emptyExtension
        case .superfluousIgnoreCommand:
            .superfluousIgnore
        case .assignOnlyProperty, .enumCaseNeverConstructed, .redundantProtocol, .unusedAssetCatalogSymbol,
             .missingMetalFunction:
            nil
        }
    }
}
