/// Why a result was not fixed.
enum SkipReason: Error, Hashable, Sendable, CustomStringConvertible {
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
    case uncoveredConditionalName
    case uncoveredConditionalType
    case implicitMemberWithUncoveredCode
    case uncoveredConditionalCode
    case partialScan(String)
    case dependencyPackage
    case libraryProduct
    case openMember
    case outsideProject
    case ignoredByGit
    case gitFailed(String)

    var description: String {
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
        case .uncoveredConditionalName: "name written in an #if clause that no scanned build compiled"
        case .uncoveredConditionalType: "member of a type declared, extended or inherited from in an #if clause that no scanned build compiled"
        case .implicitMemberWithUncoveredCode: "subscript, operator or implicitly called member, with code in an #if clause that no scanned build compiled"
        case .uncoveredConditionalCode: "file with code in an #if clause that no scanned build compiled"
        case let .partialScan(reason): "partial scan (\(reason)), use --allow-partial-scan"
        case .dependencyPackage: "dependency package"
        case .libraryProduct: "public API of a library product, clients outside the scan may use it"
        case .openMember: "open member"
        case .outsideProject: "outside the project root"
        case .ignoredByGit: "ignored by git"
        case let .gitFailed(message): message
        }
    }
}
