import PeripheryKit
import SourceGraph
import SystemPackage

/// A result to fix, located by the position of its name as the scan reported it.
public struct FixTarget: Hashable, Sendable {
    public let rule: FixRule
    public let name: String
    public let kind: Declaration.Kind
    public let file: FilePath
    public let line: Int
    public let column: Int
    /// The redundant access level, for `redundantAccessLevel`.
    public let accessibility: Accessibility?
    /// Whether the declaration carries an `override location=` comment, so its reported position is not its own.
    public let hasLocationOverride: Bool
    /// The output v2 id of the result, which keys its edit; nil for a target that is not built from a result.
    public let id: String?
    /// For `unused`, why the declaration may not be removed if it turns out to be a stored property.
    public let storedPropertyRefusal: SkipReason?

    public init(
        rule: FixRule,
        name: String,
        kind: Declaration.Kind,
        file: FilePath,
        line: Int,
        column: Int,
        accessibility: Accessibility? = nil,
        hasLocationOverride: Bool = false,
        id: String? = nil,
        storedPropertyRefusal: SkipReason? = nil
    ) {
        self.rule = rule
        self.name = name
        self.kind = kind
        self.file = file
        self.line = line
        self.column = column
        self.accessibility = accessibility
        self.hasLocationOverride = hasLocationOverride
        self.id = id
        self.storedPropertyRefusal = storedPropertyRefusal
    }

    /// The same target, with the reason that applies if it is a stored property.
    func refusingStoredProperty(_ reason: SkipReason?) -> FixTarget {
        FixTarget(
            rule: rule, name: name, kind: kind, file: file, line: line, column: column, accessibility: accessibility,
            hasLocationOverride: hasLocationOverride, id: id, storedPropertyRefusal: reason
        )
    }

    /// The target of a scan result, or nil when no rule applies to it.
    public init?(result: ScanResult) {
        let declaration = result.resultDeclaration
        let rule: FixRule
        var accessibility: Accessibility?

        switch result.fixableKind {
        case nil:
            guard result.isUnusedDeclaration else { return nil }

            rule = .unused
        case .redundantPublic: rule = .redundantPublic
        case .redundantOpen: rule = .redundantOpen
        case let .redundantAccessLevel(level):
            rule = .redundantAccessLevel
            accessibility = level
        case .emptyExtension: rule = .emptyExtension
        case .unusedImport: rule = .unusedImport
        case .superfluousIgnore: rule = .superfluousIgnore
        case .unusedParameter: rule = .unusedParameter
        case .missingFinal: rule = .missingFinal
        }

        let location = declaration.location
        self.init(
            rule: rule,
            name: declaration.name,
            kind: declaration.kind,
            file: location.file.path,
            line: location.line,
            column: location.column,
            accessibility: accessibility,
            hasLocationOverride: declaration.commentCommands.locationOverride != nil
                || declaration.parent?.commentCommands.locationOverride != nil,
            id: result.outputV2Id
        )
    }
}
