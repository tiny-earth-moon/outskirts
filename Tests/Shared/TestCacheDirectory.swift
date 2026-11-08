import Foundation
import SystemPackage

/// The build cache of the tests, in the temporary directory: the tests never write to the user's outskirts cache. It is
/// kept between runs so that the builds of the fixtures stay incremental.
public enum TestCacheDirectory {
    public static let path = FilePath(FileManager.default.temporaryDirectory.appendingPathComponent("outskirts-tests-cache").path)
}
