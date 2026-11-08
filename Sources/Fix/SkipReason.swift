/// Why a result was not fixed.
public enum SkipReason: Error, Hashable, Sendable, CustomStringConvertible {
    case locationMismatch
    case indexExcluded
    case generatedFile
    case locationOverride
    case exportedImport
    case testableImport
    case conditionalImport
    case changedSinceIndexing
    case uncommittedChanges
    case notInGitRepository
    case outsideRepository
    case nestedRepository
    case symbolicLink
    case unreadableFile
    case overlappingEdit
    case modifierNotFound
    case multipleBindings
    case extensionNotEmpty
    case ignoreCommentNotFound
    case partialParameterIgnore
    case alreadyFinal
    case openClass
    case unremovableKind
    case excludedModifier(String)
    case excludedAttribute(String)
    case retainedAttribute
    case containsExcludedDeclaration
    case caseIterableEnumCase
    case codableEnumCase
    case implicitRawValues
    case severalCases
    case referencedByKeptCode
    case requirementImplementedElsewhere
    case relatedToKeptCode
    case extensionKept
    case extendedTypeKept
    case attributedStoredProperty
    case nonLiteralInitializer
    case staticInitializer
    case memberwiseInitializerUsed
    case synthesizedConformance
    case uncoveredConditionalName
    case uncoveredConditionalType
    case implicitMemberWithUncoveredCode
    case publicDeclaration
    case storedPropertyNotIncluded
    case frozenType
    case dependencyPackage

    public var description: String {
        switch self {
        case .locationMismatch: "location mismatch"
        case .indexExcluded: "index-excluded file"
        case .generatedFile: "generated file"
        case .locationOverride: "location-override comment"
        case .exportedImport: "exported import"
        case .testableImport: "testable import"
        case .conditionalImport: "conditional import"
        case .changedSinceIndexing: "file changed since indexing"
        case .uncommittedChanges: "uncommitted changes, use --allow-dirty"
        case .notInGitRepository: "not in a git repository, use --allow-dirty"
        case .outsideRepository: "outside the git repository of the project"
        case .nestedRepository: "in a submodule or a nested git repository"
        case .symbolicLink: "symbolic link"
        case .unreadableFile: "unreadable file"
        case .overlappingEdit: "overlapping edit"
        case .modifierNotFound: "modifier not found"
        case .multipleBindings: "declaration with several bindings"
        case .extensionNotEmpty: "extension not empty"
        case .ignoreCommentNotFound: "ignore comment not found"
        case .partialParameterIgnore: "some ignored parameters are still unused"
        case .alreadyFinal: "already final"
        case .openClass: "open class"
        case .unremovableKind: "kind not removed by fix"
        case let .excludedModifier(modifier): "'\(modifier)' declaration"
        case let .excludedAttribute(attribute): "'@\(attribute)' declaration"
        case .retainedAttribute: "attribute listed in retain_attributes"
        case .containsExcludedDeclaration: "contains an @objc, dynamic, retained or ignored member"
        case .caseIterableEnumCase: "case of a CaseIterable enum"
        case .codableEnumCase: "case of a Codable enum"
        case .implicitRawValues: "later cases have implicit raw values"
        case .severalCases: "declaration with several cases"
        case .referencedByKeptCode: "referenced by code that is kept"
        case .requirementImplementedElsewhere: "protocol requirement implemented by kept code"
        case .relatedToKeptCode: "overridden by kept code, or implements a kept requirement"
        case .extensionKept: "an extension of the type is kept"
        case .extendedTypeKept: "the extended type is kept"
        case .attributedStoredProperty: "stored property with an attribute or property wrapper"
        case .nonLiteralInitializer: "stored property with a non-literal initializer"
        case .staticInitializer: "static stored property with an initializer"
        case .memberwiseInitializerUsed: "the memberwise initializer of the struct is used"
        case .synthesizedConformance: "stored property of a type with a synthesized Equatable, Hashable or Codable conformance"
        case .uncoveredConditionalName: "name written in an #if clause that no scanned build compiled"
        case .uncoveredConditionalType: "member of a type declared, extended or inherited from in an #if clause that no scanned build compiled"
        case .implicitMemberWithUncoveredCode: "subscript, operator or implicitly called member, with code in an #if clause that no scanned build compiled"
        case .publicDeclaration: "public API, use --include-public"
        case .storedPropertyNotIncluded: "stored property, use --include-stored-properties"
        case .frozenType: "stored property of a @frozen type"
        case .dependencyPackage: "dependency package"
        }
    }
}
