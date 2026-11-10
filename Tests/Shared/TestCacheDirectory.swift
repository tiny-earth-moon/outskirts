import Foundation
import SystemPackage

/// A cache directory private to the running test process, so that tests which build never touch the user's cache.
/// It is removed when the process exits.
public enum TestCacheDirectory {
    public static let path: FilePath = {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("outskirts-tests-cache-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            fatalError("Failed to create the test cache directory at \(url.path): \(error)")
        }
        atexit { TestCacheDirectory.remove() }
        return FilePath(url.path)
    }()

    private static func remove() {
        do {
            try FileManager.default.removeItem(atPath: path.string)
        } catch {
            FileHandle.standardError.write(Data("Failed to remove the test cache directory \(path.string): \(error)\n".utf8))
        }
    }
}
