import FilenameMatcher
import Foundation

public extension FilenameMatcher {
    @inlinable
    init(relativePattern: String, to base: String, caseSensitive: Bool) {
        let patternComponents = relativePattern.split(separator: "/", omittingEmptySubsequences: false)
        let parentTraversalCount = patternComponents.firstIndex { $0 != ".." } ?? 0

        if parentTraversalCount > base.split(separator: "/").count {
            self.init(pattern: "")
            return
        }

        let baseComponents = base.split(separator: "/", omittingEmptySubsequences: false)
        let traversedPattern = patternComponents.dropFirst(parentTraversalCount).joined(separator: "/")
        let traversedBaseParts = baseComponents.dropLast(parentTraversalCount)
        let traversedBase = traversedBaseParts.joined(separator: "/")
        let literalBase = Self.escapingGlobMetacharacters(in: traversedBase)
        let normalizedBase = literalBase.hasSuffix("/") ? literalBase : "\(literalBase)/"
        let shouldPrependPwd = !["/", "*"].contains { relativePattern.hasPrefix($0) }
        let pattern = shouldPrependPwd ? "\(normalizedBase)\(traversedPattern)" : traversedPattern
        self.init(pattern: pattern, options: caseSensitive ? [.caseSensitive] : [])
    }

    /// Wraps the characters that `FilenameMatcher` treats as wildcards in a bracket expression, so that a project path
    /// such as `App [beta]` matches itself.
    @inlinable
    static func escapingGlobMetacharacters(in path: String) -> String {
        path.reduce(into: "") { result, character in
            if "*?[".contains(character) {
                result += "[\(character)]"
            } else {
                result.append(character)
            }
        }
    }
}
