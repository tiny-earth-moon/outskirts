import Configuration
import SourceGraph

extension ScanResult {
    /// The rule the result belongs to. An unconstructed enum case and a missing Metal function have no rule of their
    /// own: they are dead code and count as `unused`.
    var rule: RuleIdentifier {
        switch annotation {
        case .unused:
            switch declaration.kind {
            case .module: .unusedImport
            case .varParameter: .unusedParameter
            case .localizedString: .unusedLocalizedString
            default: .unused
            }
        case .enumCaseNeverConstructed, .missingMetalFunction:
            .unused
        case .assignOnlyProperty:
            .assignOnlyProperty
        case .unassignedOptionalProperty:
            .unassignedOptional
        case .redundantProtocol:
            .redundantProtocol
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
        case let .unusedAssetCatalogSymbol(symbol):
            switch symbol.kind {
            case .color: .unusedAssetColor
            case .image: .unusedAssetImage
            }
        }
    }
}
