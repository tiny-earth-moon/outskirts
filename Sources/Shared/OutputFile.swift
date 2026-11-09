import Foundation
import SystemPackage

/// Writes the files outskirts produces besides the fixes. Each file is written atomically: the contents go to a
/// temporary file that replaces the destination, so that an interrupted run never leaves a truncated file.
public enum OutputFile {
    /// Writes a file the user named (`--write-baseline`, `--write-results`, `--config`…). A symbolic link at the
    /// destination is kept and the file it leads to is written, atomically next to it: the user chose the path, link
    /// included. Returns the path written.
    @discardableResult
    public static func write(_ data: Data, to path: FilePath) throws -> FilePath {
        let destination = try isSymbolicLink(path.string) ? linkTarget(of: path) : path
        try data.write(to: URL(fileURLWithPath: destination.string), options: .atomic)
        return destination
    }

    /// Writes a file whose path comes from the configuration file (`baseline`, `write_baseline`, `write_results`), which
    /// is project content: a cloned project could link it anywhere. A symbolic link at the destination is followed only
    /// when the file it leads to is inside `projectRoot`, and a dangling link is refused rather than creating its
    /// target; a path inside the project root must not leave it through a linked directory either. Returns the path
    /// written.
    @discardableResult
    public static func writeConfigured(_ data: Data, to path: FilePath, projectRoot: FilePath) throws -> FilePath {
        let hint = "outskirts does not write there; name the file on the command line to write it anyway."
        let destination: FilePath
        if isSymbolicLink(path.string) {
            guard resolve(path) != nil else {
                throw PeripheryError.usageError("\(path.string), from the configuration file, is a dangling symbolic link: \(hint)")
            }

            destination = try confinedRealPath(of: path, within: projectRoot, from: "the configuration file", hint: hint)
        } else {
            let root = FilePath(FileManager.default.currentDirectoryPath).pushing(projectRoot).lexicallyNormalized()
            let absolute = FilePath(FileManager.default.currentDirectoryPath).pushing(path).lexicallyNormalized()
            if try absolute.starts(with: root) || absolute.starts(with: FilePath(realPath(projectRoot))) {
                try confinedRealPath(of: path, within: projectRoot, from: "the configuration file", hint: hint)
            }
            destination = path
        }

        try data.write(to: URL(fileURLWithPath: destination.string), options: .atomic)
        return destination
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
        try confinedRealPath(of: path, within: root, from: nil, hint: "outskirts does not write there.")
    }

    /// Whether the last component of `path` is a symbolic link.
    public static func isSymbolicLink(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK
    }

    // MARK: - Private

    @discardableResult
    private static func confinedRealPath(of path: FilePath, within root: FilePath, from source: String?, hint: String) throws -> FilePath {
        let realRoot = try realPath(root)
        let resolved = try realPathAllowingMissingLeaf(path)
        let prefix = realRoot.hasSuffix("/") ? realRoot : realRoot + "/"
        guard resolved == realRoot || resolved.hasPrefix(prefix) else {
            let origin = source.map { ", from \($0)," } ?? ""
            throw PeripheryError.usageError("\(path.string)\(origin) leads to \(resolved), outside \(realRoot), \(hint)")
        }

        return FilePath(resolved)
    }

    /// The file a link leads to, every link resolved; a dangling link leads to the file its last link names, which
    /// the write then creates.
    private static func linkTarget(of path: FilePath) throws -> FilePath {
        if let resolved = resolve(path) {
            return FilePath(resolved)
        }

        var current = path
        for _ in 0 ..< 32 where isSymbolicLink(current.string) {
            let destination = try FilePath(FileManager.default.destinationOfSymbolicLink(atPath: current.string))
            current = destination.isAbsolute ? destination : current.removingLastComponent().pushing(destination)
        }
        return current.lexicallyNormalized()
    }

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
