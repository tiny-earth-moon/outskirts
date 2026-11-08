import Foundation
import Shared

public extension Xcodebuild {
    /// Holds the DerivedData folder of a build for the rest of the scan, so that concurrent scans never evict it.
    func holdCache(_ lease: CacheLease, project: XcodeProjectlike, schemes: [String], buildArguments: [String], creating: Bool) throws {
        let directory = try derivedDataPath(for: project, schemes: schemes, buildArguments: buildArguments)
        try lease.hold(URL(fileURLWithPath: directory.string), creating: creating)
    }

    /// Refreshes the build cache around the DerivedData folders of the builds of the current scan, one per list of
    /// build arguments. Throws only when the DerivedData folders cannot be resolved; housekeeping failures are returned.
    func refreshCache(project: XcodeProjectlike, schemes: [String], buildArgumentsOfEachBuild: [[String]], maxAgeDays: Int, maxSizeGB: Int = 0) throws -> CacheRefreshResult {
        let directories = try buildArgumentsOfEachBuild.map { try derivedDataPath(for: project, schemes: schemes, buildArguments: $0) }
        return CacheManager.refresh(
            directories: directories.map { URL(fileURLWithPath: $0.string) },
            projectPath: project.path.lexicallyNormalized().string,
            maxAgeDays: maxAgeDays,
            maxSizeGB: maxSizeGB,
            cacheDirectory: cacheDirectory.map { URL(fileURLWithPath: $0.string) }
        )
    }
}
