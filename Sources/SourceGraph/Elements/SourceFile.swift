import Foundation
import SystemPackage

public final class SourceFile {
    public let path: FilePath
    public let modules: Set<String>
    /// Whether the file belongs to test targets only: every module its index units compile it into is the module of a
    /// test target. A file shared with another target is not a test file.
    public let isTestFile: Bool
    public var importStatements: [ImportStatement] = []
    public var importsSwiftTesting = false
    public var usesDistributedModifier = false
    /// Whether the index store may describe an older version of the file: a unit written before the file was last
    /// modified or of unknown date, or the file changed since `index_built_from`, see `SourceFileCollector.mayBeOutdated`.
    public var hasOutdatedIndex = false

    public init(path: FilePath, modules: Set<String>, isTestFile: Bool = false) {
        self.path = path
        self.modules = modules
        self.isTestFile = isTestFile
    }
}

extension SourceFile: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(path)
    }
}

extension SourceFile: Equatable {
    public static func == (lhs: SourceFile, rhs: SourceFile) -> Bool {
        lhs.path == rhs.path
    }
}

extension SourceFile: Comparable {
    public static func < (lhs: SourceFile, rhs: SourceFile) -> Bool {
        lhs.path.string < rhs.path.string
    }
}
