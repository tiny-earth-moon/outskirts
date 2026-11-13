import Foundation
import SystemPackage

public enum DerivedDataIndexStore {
    static let relativeStorePaths = ["Index.noindex/DataStore", "Index/DataStore"]

    public static func resolve(derivedDataPath: FilePath) throws -> FilePath {
        guard directoryExists(derivedDataPath) else {
            throw PeripheryError.derivedDataPathNotFound(derivedDataPath: derivedDataPath.string)
        }

        let candidates = relativeStorePaths.map { derivedDataPath.appending($0) }
        guard let store = candidates.first(where: directoryExists) else {
            throw PeripheryError.derivedDataIndexStoreNotFound(derivedDataPath: derivedDataPath.string, tried: candidates.map(\.string))
        }

        return store
    }

    public static func merge(indexStorePaths: [FilePath], derivedDataPaths: [FilePath]) throws -> [FilePath] {
        let resolved = try derivedDataPaths.map(resolve(derivedDataPath:))
        var seen = Set<FilePath>()
        return (indexStorePaths + resolved).filter { seen.insert($0.lexicallyNormalized()).inserted }
    }

    private static func directoryExists(_ path: FilePath) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path.string, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
