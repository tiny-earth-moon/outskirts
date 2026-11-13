import Foundation
import SourceGraph
import SystemPackage

public struct IndexPlan {
    public let sourceFiles: [SourceFile: [IndexUnit]]
    public let plistPaths: Set<FilePath>
    public let xibPaths: Set<FilePath>
    public let xcDataModelPaths: Set<FilePath>
    public let xcMappingModelPaths: Set<FilePath>
    public let xcStringsPaths: Set<FilePath>
    /// The modules owning each String Catalog, for the project drivers that know the target membership of resources.
    /// A catalogue without an entry has an unknown owner.
    public let xcStringsModules: [FilePath: Set<String>]
    public let expectedSourceFiles: [String: Set<FilePath>]
    /// The module and platforms of the targets of `expectedSourceFiles`, for `strict_index_coverage`; a target
    /// without an entry is covered by index data of any module and platform for its files.
    public let coverageTargets: [String: CoverageTarget]
    /// The names of the index store units that could not be read, whose source files are missing from `sourceFiles`.
    public let unreadableUnits: [String]
    public let indexStorePaths: Set<FilePath>
    /// Values of the `ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME` build setting, `nil` when the project driver
    /// does not read build settings.
    public let globalAccentColorNames: Set<String>?

    public init(
        sourceFiles: [SourceFile: [IndexUnit]],
        plistPaths: Set<FilePath> = [],
        xibPaths: Set<FilePath> = [],
        xcDataModelPaths: Set<FilePath> = [],
        xcMappingModelPaths: Set<FilePath> = [],
        xcStringsPaths: Set<FilePath> = [],
        xcStringsModules: [FilePath: Set<String>] = [:],
        expectedSourceFiles: [String: Set<FilePath>] = [:],
        coverageTargets: [String: CoverageTarget] = [:],
        unreadableUnits: [String] = [],
        indexStorePaths: Set<FilePath> = [],
        globalAccentColorNames: Set<String>? = nil
    ) {
        self.sourceFiles = sourceFiles
        self.plistPaths = plistPaths
        self.xibPaths = xibPaths
        self.xcDataModelPaths = xcDataModelPaths
        self.xcMappingModelPaths = xcMappingModelPaths
        self.xcStringsPaths = xcStringsPaths
        self.xcStringsModules = xcStringsModules
        self.expectedSourceFiles = expectedSourceFiles
        self.coverageTargets = coverageTargets
        self.unreadableUnits = unreadableUnits
        self.indexStorePaths = indexStorePaths
        self.globalAccentColorNames = globalAccentColorNames
    }
}

enum ModelInput {
    enum Kind {
        case data
        case mapping
    }

    enum ValidationError: Error, CustomStringConvertible {
        case invalidPath(FilePath)

        var description: String {
            switch self {
            case let .invalidPath(path): "Invalid model path: \(path.string)"
            }
        }
    }

    case directory(FilePath)
    case file(FilePath)

    init(path: FilePath, kind: Kind) throws {
        switch kind {
        case .data:
            if path.extension?.lowercased() == "xcdatamodeld" {
                self = .directory(path)
            } else if path.lastComponent?.string == "contents", path.removingLastComponent().extension?.lowercased() == "xcdatamodel" {
                self = .file(path)
            } else {
                throw ValidationError.invalidPath(path)
            }
        case .mapping:
            if path.extension?.lowercased() == "xcmappingmodel" {
                self = .directory(path)
            } else if path.lastComponent?.string == "xcmapping.xml", path.removingLastComponent().extension?.lowercased() == "xcmappingmodel" {
                self = .file(path)
            } else {
                throw ValidationError.invalidPath(path)
            }
        }
    }
}
