import Foundation
import Shared
import SystemPackage

/// The files of the git working tree that changed since the revision the index was built from
/// (`--index-built-from`). A file git knows is judged by its content, whatever its modification date; a file git does
/// not know, outside the working tree or ignored, is left to its modification date.
struct GitIndexFreshness: Sendable {
    /// The revision as given, for the messages.
    let revision: String
    /// Real paths of the files added, deleted, modified or renamed (old and new path) since the revision, untracked
    /// files included.
    let changed: Set<FilePath>
    /// Real paths of the files added since the revision, untracked files included.
    let added: Set<FilePath>
    /// Real paths of the files git judges: tracked now, or changed since the revision.
    let known: Set<FilePath>

    /// Throws a typed error when the directory is outside any git working tree or the revision names no commit:
    /// freshness is never judged by date when the caller asked for git.
    static func read(revision: String, in directory: FilePath) throws -> Self {
        do {
            return try readChanges(revision: revision, in: directory)
        } catch let error as GitError {
            throw PeripheryError.underlyingError(error)
        }
    }

    /// Whether the file changed since the revision; nil when git does not know it, so its date decides.
    func hasChanged(_ file: FilePath) -> Bool? {
        let path = Self.realPath(file)
        guard known.contains(path) else { return nil }

        return changed.contains(path)
    }

    /// The changed files the index cannot account for: Swift sources added since the revision that no unit describes,
    /// and changed files that outskirts reads besides the index (see `readByScan`). Only the files in `root` count.
    func unindexedChanges(indexed: Set<FilePath>, in root: FilePath, isExcluded: (FilePath) -> Bool) -> Set<FilePath> {
        let root = Self.realPath(root)
        let indexed = Set(indexed.map(Self.realPath))

        return changed.filter { file in
            guard file.starts(with: root), !isExcluded(file) else { return false }

            if Self.isReadByScan(file) {
                return true
            }

            return file.extension == "swift" && added.contains(file) && !indexed.contains(file)
        }
    }

    /// The files outskirts reads besides the index store, whose changes alter the results: Interface Builder files,
    /// property lists, String Catalogs, Metal sources, Core Data models and mappings, asset catalogs, Xcode projects and
    /// workspaces, and package manifests.
    static func isReadByScan(_ file: FilePath) -> Bool {
        guard let name = file.lastComponent?.string else { return false }

        if name == "Package.swift" || (name.hasPrefix("Package@swift-") && name.hasSuffix(".swift")) {
            return true
        }

        if let fileExtension = file.extension?.lowercased(), readExtensions.contains(fileExtension) {
            return true
        }

        return file.components.dropLast().contains { component in
            component.extension.map { bundleExtensions.contains($0.lowercased()) } ?? false
        }
    }

    // MARK: - Private

    private static let readExtensions: Set<String> = ["xib", "storyboard", "plist", "xcstrings", "metal", "pbxproj", "xcworkspacedata"]
    private static let bundleExtensions: Set<String> = ["xcdatamodeld", "xcdatamodel", "xcmappingmodel", "xcassets"]

    private static func readChanges(revision: String, in directory: FilePath) throws -> Self {
        guard let topLevel = try Git.topLevel(of: directory) else {
            throw PeripheryError.indexBuiltFromNotInGitWorkTree(path: directory.string)
        }

        let root = FilePath(topLevel)
        let commit: String
        do {
            guard !revision.hasPrefix("-") else {
                throw GitError.failed(command: "rev-parse", status: 0, message: "a revision cannot start with '-'")
            }

            commit = try Git.run(["rev-parse", "--verify", "\(revision)^{commit}"], in: root)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch let GitError.failed(_, _, message) {
            throw PeripheryError.indexBuiltFromUnknownRevision(revision: revision, repository: topLevel, message: message)
        }

        // Without renames, a renamed file is its deleted old path and its added new path.
        let status = try Git.run(["-c", "core.quotePath=false", "diff", "--name-status", "-z", "--no-renames", commit, "--"], in: root)
            .split(separator: "\0", omittingEmptySubsequences: true)
        var changed: Set<FilePath> = []
        var added: Set<FilePath> = []
        for index in stride(from: 0, to: status.count - 1, by: 2) {
            let path = root.appending(String(status[index + 1]))
            changed.insert(path)
            if status[index] == "A" {
                added.insert(path)
            }
        }

        // git does not track a file through a linked directory, so the paths it lists are real paths.
        let untracked = try Git.run(["ls-files", "--others", "--exclude-standard", "-z"], in: root)
            .split(separator: "\0")
            .map { root.appending(String($0)) }
        changed.formUnion(untracked)
        added.formUnion(untracked)

        let tracked = try Git.run(["ls-files", "-z"], in: root)
            .split(separator: "\0")
            .map { root.appending(String($0)) }

        return Self(revision: revision, changed: changed, added: added, known: changed.union(tracked))
    }

    /// The real path of a file, or of its directory for a file that no longer exists.
    private static func realPath(_ file: FilePath) -> FilePath {
        if file.exists {
            return FilePath(RealPath.resolve(file.string))
        }

        guard let name = file.lastComponent else { return file }

        return FilePath(RealPath.resolve(file.removingLastComponent().string)).appending(name)
    }
}
