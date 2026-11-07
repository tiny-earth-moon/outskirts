import Foundation
import Shared

public extension Xcodebuild {
    /// Refreshes the build cache around the DerivedData folders of the builds of the current scan, one per list of
    /// build arguments. Returns the evicted entries.
    func refreshCache(project: XcodeProjectlike, schemes: [String], buildArgumentsOfEachBuild: [[String]], maxAgeDays: Int, maxSizeGB: Int = 0) throws -> [EvictedCacheEntry] {
        let directories = try buildArgumentsOfEachBuild.map { try derivedDataPath(for: project, schemes: schemes, buildArguments: $0) }
        return try CacheManager.refresh(
            directories: directories.map { URL(fileURLWithPath: $0.string) },
            projectPath: project.path.lexicallyNormalized().string,
            maxAgeDays: maxAgeDays,
            maxSizeGB: maxSizeGB
        )
    }
}
