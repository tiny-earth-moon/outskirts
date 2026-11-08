import Foundation
import Logger

struct CacheEntryError: Error, CustomStringConvertible {
    let path: String
    let underlying: Error

    var description: String {
        "\(path): \(underlying.localizedDescription)"
    }
}

struct CacheClearError: Error, LocalizedError {
    let failures: [CacheEntryError]

    var errorDescription: String? {
        "Failed to clear the cache, the following entries could not be removed:\n"
            + failures.map { "  - \($0.description)" }.joined(separator: "\n")
    }
}

struct CacheEntryInUseError: Error, LocalizedError {
    var errorDescription: String? {
        "in use by a running scan"
    }
}

struct EvictedCacheEntry: Equatable {
    let name: String
    let size: Int64
}

/// What a cache refresh did. Housekeeping failures never fail the scan: they are reported as warnings.
public struct CacheRefreshResult {
    var evicted: [EvictedCacheEntry] = []
    var failures: [CacheEntryError] = []

    public func report(to logger: Logger) {
        for entry in evicted {
            let size = ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file)
            logger.info("Evicted unused build cache \(entry.name) (\(size))")
        }
        for failure in failures {
            logger.warn("Could not maintain the build cache: \(failure.description)")
        }
    }
}

public enum CacheManager {
    static let derivedDataPrefix = "DerivedData-"
    /// The scratch paths of the Swift package builds of the `variants` setting.
    public static let packageBuildPrefix = "PackageBuild-"
    /// The cache entries subject to eviction.
    static let evictablePrefixes = [derivedDataPrefix, packageBuildPrefix]
    static let projectSidecarName = ".outskirts-project"
    /// Its modification date is the start of the last eviction sweep of the cache.
    static let evictionStampName = ".outskirts-last-eviction"
    /// A scan sweeps the cache at most once per interval: a sweep measures every build folder.
    static let evictionInterval: TimeInterval = 3600

    /// Clears the outskirts cache directory and the one left by releases that predate the rename.
    public static func clearIncludingLegacy(cachesDirectory: URL? = nil, fileManager: FileManager = .default) throws {
        try clear(cacheDirectory: URL(fileURLWithPath: Constants.cachePath(cachesDirectory: cachesDirectory).string), fileManager: fileManager)
        try clear(cacheDirectory: URL(fileURLWithPath: Constants.legacyCachePath(cachesDirectory: cachesDirectory).string), fileManager: fileManager)
    }

    /// Removes every entry of the cache directory, then the directory itself. Entries that have already
    /// vanished are ignored, the build folders a running scan holds are reported. Symbolic links are removed, never followed.
    static func clear(cacheDirectory: URL, fileManager: FileManager = .default) throws {
        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(
                at: cacheDirectory,
                includingPropertiesForKeys: nil,
                options: []
            )
        } catch {
            if !fileManager.fileExists(atPath: cacheDirectory.path) {
                return
            }
            throw CacheClearError(failures: [CacheEntryError(path: cacheDirectory.path, underlying: error)])
        }

        var failures: [CacheEntryError] = []
        for entry in entries {
            do {
                if try !removeUnlessInUse(entry, fileManager: fileManager) {
                    failures.append(CacheEntryError(path: entry.path, underlying: CacheEntryInUseError()))
                }
            } catch {
                if !isMissing(error) {
                    failures.append(CacheEntryError(path: entry.path, underlying: error))
                }
            }
        }

        if failures.isEmpty {
            do {
                try fileManager.removeItem(at: cacheDirectory)
            } catch {
                if !isMissing(error) {
                    failures.append(CacheEntryError(path: cacheDirectory.path, underlying: error))
                }
            }
        }

        if !failures.isEmpty {
            throw CacheClearError(failures: failures)
        }
    }

    /// Records the project in each build folder of the current scan (DerivedData folder or scratch path) and marks it
    /// as used, then evicts the stale folders from the cache, keeping the current ones, unless the cache was swept less
    /// than `evictionInterval` ago. Never throws: the failures are returned with the evicted entries.
    public static func refresh(
        directories: [URL],
        projectPath: String,
        maxAgeDays: Int,
        maxSizeGB: Int,
        cacheDirectory: URL? = nil,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) -> CacheRefreshResult {
        var failures: [CacheEntryError] = []
        for directory in directories where fileManager.fileExists(atPath: directory.path) {
            do {
                try recordProject(projectPath, in: directory, fileManager: fileManager)
                try touch(directory, fileManager: fileManager)
            } catch {
                failures.append(error as? CacheEntryError ?? CacheEntryError(path: directory.path, underlying: error))
            }
        }

        let cache: URL
        if let cacheDirectory {
            cache = cacheDirectory
        } else {
            do {
                cache = try URL(fileURLWithPath: Constants.cachePath().string)
            } catch {
                return CacheRefreshResult(failures: failures + [CacheEntryError(path: "cache directory", underlying: error)])
            }
        }

        var result = evictStale(
            cacheDirectory: cache,
            maxAgeDays: maxAgeDays,
            maxSizeBytes: Int64(maxSizeGB) << 30,
            keeping: directories,
            minimumInterval: evictionInterval,
            now: now,
            fileManager: fileManager
        )
        result.failures.insert(contentsOf: failures, at: 0)
        return result
    }

    /// Marks a DerivedData folder as used now.
    static func touch(_ directory: URL, now: Date = Date(), fileManager: FileManager = .default) throws {
        try fileManager.setAttributes([.modificationDate: now], ofItemAtPath: directory.path)
    }

    /// Records the project a DerivedData folder was built for, so that the folder can be evicted once the project is gone.
    /// Call it before `touch`: creating the file changes the folder's modification date.
    static func recordProject(_ projectPath: String, in directory: URL, fileManager: FileManager = .default) throws {
        let sidecar = directory.appendingPathComponent(projectSidecarName)
        guard let data = projectPath.data(using: .utf8) else { return }

        if !fileManager.createFile(atPath: sidecar.path, contents: data) {
            throw CacheEntryError(path: sidecar.path, underlying: CocoaError(.fileWriteUnknown))
        }
    }

    @discardableResult
    static func evictStale(
        cacheDirectory: URL,
        maxAgeDays: Int,
        maxSizeBytes: Int64 = 0,
        keeping: URL?,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) -> CacheRefreshResult {
        evictStale(
            cacheDirectory: cacheDirectory,
            maxAgeDays: maxAgeDays,
            maxSizeBytes: maxSizeBytes,
            keeping: keeping.map { [$0] } ?? [],
            now: now,
            fileManager: fileManager
        )
    }

    /// Removes the `DerivedData-*` and `PackageBuild-*` folders of the cache, except `keeping` and the folders a running
    /// scan holds (see `CacheLease`), that are stale. A folder is stale when
    /// the project recorded in its sidecar no longer exists, or when its modification date is older than
    /// `maxAgeDays` (0 disables this age rule). Then, when `maxSizeBytes` is above 0, the least recently
    /// used folders are removed until the folders left fit in `maxSizeBytes` bytes (the size of `keeping` counts).
    /// The folders that cannot be removed are returned as failures, never thrown. When `minimumInterval` is above 0,
    /// nothing is read when the previous sweep started less than `minimumInterval` seconds before `now`.
    @discardableResult
    static func evictStale(
        cacheDirectory: URL,
        maxAgeDays: Int,
        maxSizeBytes: Int64 = 0,
        keeping: [URL],
        minimumInterval: TimeInterval = 0,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) -> CacheRefreshResult {
        guard fileManager.fileExists(atPath: cacheDirectory.path) else { return CacheRefreshResult() }

        var failures: [CacheEntryError] = []
        if minimumInterval > 0 {
            let stamp = cacheDirectory.appendingPathComponent(evictionStampName)
            do {
                if let last = try lastSweep(stamp, fileManager: fileManager), last <= now, now.timeIntervalSince(last) < minimumInterval {
                    return CacheRefreshResult()
                }
                try markSweep(stamp, now: now, fileManager: fileManager)
            } catch {
                failures.append(CacheEntryError(path: stamp.path, underlying: error))
            }
        }

        let cutoff = now.addingTimeInterval(-Double(maxAgeDays) * 86400)
        let keptNames = Set(keeping.map(\.lastPathComponent))
        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(
                at: cacheDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: []
            )
        } catch {
            return CacheRefreshResult(failures: failures + [CacheEntryError(path: cacheDirectory.path, underlying: error)])
        }

        var evicted: [EvictedCacheEntry] = []
        var remaining: [(url: URL, modified: Date, size: Int64)] = []
        var keptSize: Int64 = 0

        func remove(_ entry: URL, size: Int64) -> Bool {
            do {
                guard try removeUnlessInUse(entry, fileManager: fileManager) else { return false }

                evicted.append(EvictedCacheEntry(name: entry.lastPathComponent, size: size))
                return true
            } catch {
                if isMissing(error) {
                    return true
                }
                failures.append(CacheEntryError(path: entry.path, underlying: error))
                return false
            }
        }

        for entry in entries where evictablePrefixes.contains(where: entry.lastPathComponent.hasPrefix) {
            let isKept = keptNames.contains(entry.lastPathComponent)
            let modified: Date?
            do {
                modified = try entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            } catch {
                failures.append(CacheEntryError(path: entry.path, underlying: error))
                continue
            }
            let isStale = !isKept
                && (isOrphan(entry, fileManager: fileManager) || (maxAgeDays > 0 && (modified.map { $0 < cutoff } ?? false)))
            if !isStale, maxSizeBytes == 0 {
                continue
            }

            let size = directorySize(entry, fileManager: fileManager)
            if isStale, remove(entry, size: size) {
                continue
            }
            if isStale || isKept {
                // A stale folder left in place, in use or not removable, still takes room.
                keptSize += size
            } else {
                remaining.append((entry, modified ?? .distantPast, size))
            }
        }

        if maxSizeBytes > 0 {
            let limit = maxSizeBytes
            var total = keptSize + remaining.reduce(0) { $0 + $1.size }
            for candidate in remaining.sorted(by: { $0.modified < $1.modified }) where total > limit {
                if remove(candidate.url, size: candidate.size) {
                    total -= candidate.size
                }
            }
        }

        return CacheRefreshResult(evicted: evicted, failures: failures)
    }

    // MARK: - Private

    private static func lastSweep(_ stamp: URL, fileManager: FileManager) throws -> Date? {
        guard fileManager.fileExists(atPath: stamp.path) else { return nil }

        return try fileManager.attributesOfItem(atPath: stamp.path)[.modificationDate] as? Date
    }

    private static func markSweep(_ stamp: URL, now: Date, fileManager: FileManager) throws {
        if !fileManager.fileExists(atPath: stamp.path), !fileManager.createFile(atPath: stamp.path, contents: nil) {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: stamp.path])
        }
        try fileManager.setAttributes([.modificationDate: now], ofItemAtPath: stamp.path)
    }

    /// Removes a cache entry under an exclusive lock, unless a running scan holds it. Returns false when it is in use.
    private static func removeUnlessInUse(_ entry: URL, fileManager: FileManager) throws -> Bool {
        let type = try fileManager.attributesOfItem(atPath: entry.path)[.type] as? FileAttributeType
        guard type == .typeDirectory else {
            try fileManager.removeItem(at: entry)
            return true
        }
        guard let descriptor = try CacheLock.tryExclusive(in: entry) else { return false }

        defer { close(descriptor) }
        try fileManager.removeItem(at: entry)
        return true
    }

    /// Whether the folder records a project path that no longer exists. A folder without a sidecar is never an orphan,
    /// nor is one whose project is on a volume that is not mounted: the age and size rules apply to it.
    private static func isOrphan(_ directory: URL, fileManager: FileManager) -> Bool {
        let sidecar = directory.appendingPathComponent(projectSidecarName)
        guard let data = fileManager.contents(atPath: sidecar.path),
              let path = String(data: data, encoding: .utf8), !path.isEmpty else { return false }

        let components = URL(fileURLWithPath: path).pathComponents
        if components.count > 2, components[1] == "Volumes",
           !fileManager.fileExists(atPath: "/Volumes/\(components[2])")
        {
            return false
        }
        return !fileManager.fileExists(atPath: path)
    }

    private static func isMissing(_ error: Error) -> Bool {
        let nsError = error as NSError
        return (nsError.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(nsError.code))
            || (nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOENT))
    }

    private static func directorySize(_ url: URL, fileManager: FileManager) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: []
        ) else { return 0 }

        var total: Int64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else { continue }

            total += Int64(values.fileSize ?? 0)
        }
        return total
    }
}
