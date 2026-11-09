import Foundation
import SystemPackage

/// Writes the files outskirts produces besides the fixes. Each file is written atomically: the contents go to a
/// temporary file that replaces the destination, so that an interrupted run never leaves a truncated file.
public enum OutputFile {
    /// Writes a file the user named (`--write-baseline`, `--write-results`…). A symbolic link at the destination is
    /// refused: replacing it would silently cut the link, writing through it would silently write elsewhere.
    public static func write(_ data: Data, to path: FilePath) throws {
        if isSymbolicLink(path.string) {
            throw PeripheryError.usageError("\(path.string) is a symbolic link, outskirts does not write through it: pass the path of the file it leads to.")
        }

        try data.write(to: URL(fileURLWithPath: path.string), options: .atomic)
    }

    /// Writes a file outskirts chose itself, at the real path of `path`, which must be inside `root`, so that a
    /// symbolic link never leads the write elsewhere. A link inside `root` is kept, the file it leads to is written.
    /// Returns the real path written.
    @discardableResult
    public static func writeConfined(_ data: Data, to path: FilePath, within root: FilePath) throws -> FilePath {
        let realPath = try confinedRealPath(of: path, within: root)
        try data.write(to: URL(fileURLWithPath: realPath.string), options: .atomic)
        return realPath
    }

    /// The real path of `path`, its symbolic links resolved, that of its last component too when it exists. Throws
    /// when it is outside the real path of `root`.
    @discardableResult
    public static func confinedRealPath(of path: FilePath, within root: FilePath) throws -> FilePath {
        let realRoot = try realPath(root)
        let resolved = try realPathAllowingMissingLeaf(path)
        let prefix = realRoot.hasSuffix("/") ? realRoot : realRoot + "/"
        guard resolved == realRoot || resolved.hasPrefix(prefix) else {
            throw PeripheryError.usageError("\(path.string) leads to \(resolved), outside \(realRoot), outskirts does not write there.")
        }

        return FilePath(resolved)
    }

    /// Whether the last component of `path` is a symbolic link.
    public static func isSymbolicLink(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK
    }

    // MARK: - Private

    private static func realPath(_ path: FilePath) throws -> String {
        guard let resolved = resolve(path) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: path.string])
        }

        return resolved
    }

    private static func resolve(_ path: FilePath) -> String? {
        guard let resolved = realpath(path.isEmpty ? "." : path.string, nil) else { return nil }

        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// A missing file, or a dangling link, resolves through its directory: the write replaces it there.
    private static func realPathAllowingMissingLeaf(_ path: FilePath) throws -> String {
        if let resolved = resolve(path) {
            return resolved
        }
        guard let leaf = path.lastComponent else { return try realPath(path) }

        let parent = try realPath(path.removingLastComponent())
        return parent.hasSuffix("/") ? parent + leaf.string : parent + "/" + leaf.string
    }
}
