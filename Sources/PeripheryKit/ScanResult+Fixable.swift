import SourceGraph

public extension ScanResult {
    /// The result kinds that `outskirts fix` knows how to apply.
    enum FixableKind: Equatable, Sendable {
        case redundantPublic
        case redundantOpen
        case redundantAccessLevel(Accessibility)
        case emptyExtension
        case unusedImport
        case superfluousIgnore
        case unusedParameter
        case missingFinal
    }

    /// The fix this result calls for, or nil when it cannot be fixed by a syntax-only edit.
    var fixableKind: FixableKind? {
        switch annotation {
        case .redundantPublicAccessibility:
            .redundantPublic
        case .redundantOpenAccessibility:
            .redundantOpen
        case let .redundantAccessLevel(redundant):
            .redundantAccessLevel(redundant.accessibility)
        case .emptyExtension:
            .emptyExtension
        case .superfluousIgnoreCommand:
            .superfluousIgnore
        case .unused where declaration.kind == .module:
            .unusedImport
        case .unused where declaration.kind == .varParameter:
            .unusedParameter
        case .missingFinal where declaration.kind == .class:
            .missingFinal
        default:
            nil
        }
    }

    /// Whether the result is an unused declaration that `fix --rule unused` may remove: not an import, a parameter, a
    /// String Catalog key or an asset, and not an unconstructed enum case, which patterns still name.
    var isUnusedDeclaration: Bool {
        guard case .unused = annotation else { return false }

        return ![.module, .varParameter, .localizedString].contains(declaration.kind)
    }

    /// The output v2 id of the result, which keys its edits.
    var outputV2Id: String {
        OutputV2Id.id(of: self)
    }

    /// The declaration the result is about.
    var resultDeclaration: Declaration {
        declaration
    }
}
