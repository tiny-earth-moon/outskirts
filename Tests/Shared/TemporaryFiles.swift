import Foundation
import SystemPackage

/// A unique, not yet created, location in the temporary directory: `<prefix>-<UUID><suffix>`, or `<UUID><suffix>` without a prefix.
public func uniqueTemporaryURL(_ prefix: String? = nil, suffix: String = "") -> URL {
    let name = [prefix, UUID().uuidString].compactMap(\.self).joined(separator: "-") + suffix
    return FileManager.default.temporaryDirectory.appendingPathComponent(name)
}

/// Creates a unique directory in the temporary directory and returns it; removing it is the caller's job.
public func makeTemporaryDirectory(_ prefix: String? = nil, suffix: String = "") throws -> URL {
    let url = uniqueTemporaryURL(prefix, suffix: suffix)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A path in the temporary directory that does not exist, for tests of missing input files.
public func missingPath(_ fileExtension: String) -> FilePath {
    FilePath(uniqueTemporaryURL("Missing", suffix: ".\(fileExtension)").path)
}

/// Writes `contents` as UTF-8 to `name` in `directory` and returns the file's path.
@discardableResult
public func writeFile(_ contents: String, named name: String, in directory: URL) throws -> FilePath {
    let url = directory.appendingPathComponent(name)
    try contents.write(to: url, atomically: true, encoding: .utf8)
    return FilePath(url.path)
}
