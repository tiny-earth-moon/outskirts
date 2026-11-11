import Extensions
import SystemPackage

/// The files a fix run would write, each with its bytes before and after, and the files it leaves as they are.
public struct FixPlan: Sendable {
    public struct Change: Sendable {
        public let path: FilePath
        /// The real path of the file when the change was planned: the file is written there only.
        let realPath: String
        public let original: [UInt8]
        public let fixed: [UInt8]
        public let removedKeys: Set<String>
    }

    public struct Skip: Sendable {
        public let path: FilePath
        public let keys: Set<String>
        public let reason: SkipReason
    }

    public internal(set) var changes: [Change] = []
    public internal(set) var skipped: [Skip] = []

    /// The unified diff of every change, with paths relative to the given directory.
    public func diff(relativeTo root: FilePath) -> String {
        changes.map { change in
            let path = change.path.relativeTo(root).string
            guard let old = String(validating: change.original, as: UTF8.self),
                  let new = String(validating: change.fixed, as: UTF8.self)
            else { return "Binary files a/\(path) and b/\(path) differ\n" }

            return UnifiedDiff.diff(old: old, new: new, oldPath: "a/\(path)", newPath: "b/\(path)")
        }.joined()
    }

    /// One line with the counts, then one line per skipped file with its reason.
    public func summary(relativeTo root: FilePath, applying: Bool) -> String {
        let removed = changes.reduce(0) { $0 + $1.removedKeys.count }
        let skippedKeys = skipped.reduce(0) { $0 + $1.keys.count }
        let verb = applying ? "Removed" : "Would remove"
        var lines = ["\(verb) \(plural(removed, "unused String Catalog key")) in \(plural(changes.count, "file")), skipped \(plural(skippedKeys, "key"))."]
        lines += skipped.sorted { $0.path.string < $1.path.string }.map { skip in
            "  skipped \(plural(skip.keys.count, "key")) in \(skip.path.relativeTo(root).string): \(skip.reason)"
        }
        return lines.joined(separator: "\n")
    }

    private func plural(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")"
    }
}

/// Why a file was not fixed.
public enum SkipReason: Error, Equatable, Sendable, CustomStringConvertible {
    case changedSinceScan
    case uncommittedChanges
    case notInGitRepository
    case outsideRepository
    case notTrackedByGit
    case outsideProject
    case symbolicLink
    case unreadableFile
    case catalogRefused(XCStringsKeyRemovalError)

    public var description: String {
        switch self {
        case .changedSinceScan: "file changed since the scan"
        case .uncommittedChanges: "uncommitted changes, use --allow-dirty"
        case .notInGitRepository: "not in a git repository, use --allow-dirty"
        case .outsideRepository: "outside the git repository of the project"
        case .notTrackedByGit: "not tracked by git (ignored, or in a submodule or a nested repository)"
        case .outsideProject: "outside the project root"
        case .symbolicLink: "symbolic link"
        case .unreadableFile: "unreadable file"
        case let .catalogRefused(error): "\(error)"
        }
    }
}
