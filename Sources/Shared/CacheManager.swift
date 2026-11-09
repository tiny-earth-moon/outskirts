import Foundation
import Logger
import SystemPackage

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

/// Hooks around the file operations of the cache, for the tests.
struct CacheEvents: Sendable {
    var willList: @Sendable (URL) -> Void = { _ in }
    var willRemove: @Sendable (URL) -> Void = { _ in }
}

public enum CacheManager {
    @TaskLocal static var events = CacheEvents()

    static let derivedDataPrefix = "DerivedData-"
    /// The scratch paths of the Swift package builds of the `variants` setting.
    public static let packageBuildPrefix = "PackageBuild-"
    /// The cache entries subject to eviction.
    static let evictablePrefixes = [derivedDataPrefix, packageBuildPrefix]
    static let projectSidecarName = ".outskirts-project"
    /// The prefix of a build folder renamed for removal, out of reach of the scans that start meanwhile.
    static let evictingPrefix = ".evicting-"
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
    /// A cache directory that is itself a symbolic link, moved to another volume for instance, is emptied and kept, the
    /// link with it, so that the next scan builds there again.
    static func clear(cacheDirectory: URL, fileManager: FileManager = .default) throws {
        let isLink = OutputFile.isSymbolicLink(cacheDirectory.path)
        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(
                at: listable(cacheDirectory),
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

        // Not recursive: a scan may have created and locked a build folder since the listing.
        if failures.isEmpty, !isLink, rmdir(cacheDirectory.path) != 0, ![ENOENT, ENOTEMPTY, EEXIST].contains(errno) {
            let error = NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: cacheDirectory.path])
            failures.append(CacheEntryError(path: cacheDirectory.path, underlying: error))
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
        let cache: URL
        if let cacheDirectory {
            cache = cacheDirectory
        } else {
            do {
                cache = try URL(fileURLWithPath: Constants.cachePath().string)
            } catch {
                return CacheRefreshResult(failures: [CacheEntryError(path: "cache directory", underlying: error)])
            }
        }

        var failures: [CacheEntryError] = []
        for directory in directories where fileManager.fileExists(atPath: directory.path) {
            do {
                // A build folder replaced by a symbolic link must not lead the sidecar write out of the cache.
                try OutputFile.confinedRealPath(of: FilePath(directory.path), within: FilePath(cache.path))
                try recordProject(projectPath, in: directory, fileManager: fileManager)
                try touch(directory, fileManager: fileManager)
            } catch {
                failures.append(error as? CacheEntryError ?? CacheEntryError(path: directory.path, underlying: error))
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
            events.willList(cacheDirectory)
            entries = try fileManager.contentsOfDirectory(
                at: listable(cacheDirectory),
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: []
            )
        } catch {
            return CacheRefreshResult(failures: failures + [CacheEntryError(path: cacheDirectory.path, underlying: error)])
        }

        var evicted: [EvictedCacheEntry] = []
        var remaining: [(url: URL, modified: Date, size: Int64)] = []
        var keptSize: Int64 = 0

        // Leftovers of removals that were interrupted: no scan uses them.
        // Without the lock: another scan may be removing the same leftover, which is then already gone.
        for entry in entries where entry.lastPathComponent.hasPrefix(evictingPrefix) {
            do {
                events.willRemove(entry)
                try fileManager.removeItem(at: entry)
            } catch {
                if !isMissing(error) {
                    failures.append(CacheEntryError(path: entry.path, underlying: error))
                }
            }
        }

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

    /// The directory to list: listing a symbolic link to a directory gives no entries, its target does.
    private static func listable(_ directory: URL) -> URL {
        OutputFile.isSymbolicLink(directory.path) ? directory.resolvingSymlinksInPath() : directory
    }

    private static func lastSweep(_ stamp: URL, fileManager: FileManager) throws -> Date? {
        guard fileManager.fileExists(atPath: stamp.path) else { return nil }

        return try fileManager.attributesOfItem(atPath: stamp.path)[.modificationDate] as? Date
    }

    /// A symbolic link in place of the stamp is replaced by the stamp: setting its date would follow the link.
    private static func markSweep(_ stamp: URL, now: Date, fileManager: FileManager) throws {
        if OutputFile.isSymbolicLink(stamp.path) {
            try fileManager.removeItem(at: stamp)
        }
        if !fileManager.fileExists(atPath: stamp.path), !fileManager.createFile(atPath: stamp.path, contents: nil) {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: stamp.path])
        }
        try fileManager.setAttributes([.modificationDate: now], ofItemAtPath: stamp.path)
    }

    /// Removes a build folder, unless a running scan holds it. Returns false when it is in use. Under an exclusive lock,
    /// the folder is first renamed out of reach, then removed: a scan that starts meanwhile never sees it half removed.
    public static func removeUnlessInUse(_ entry: URL, fileManager: FileManager = .default) throws -> Bool {
        let type = try fileManager.attributesOfItem(atPath: entry.path)[.type] as? FileAttributeType
        guard type == .typeDirectory, !entry.lastPathComponent.hasPrefix(evictingPrefix) else {
            events.willRemove(entry)
            try fileManager.removeItem(at: entry)
            return true
        }
        guard let descriptor = try CacheLock.tryExclusive(in: entry) else { return false }

        let renamed = entry.deletingLastPathComponent().appendingPathComponent("\(evictingPrefix)\(UUID().uuidString)")
        do {
            try fileManager.moveItem(at: entry, to: renamed)
        } catch {
            close(descriptor)
            throw error
        }
        close(descriptor)
        events.willRemove(renamed)
        try fileManager.removeItem(at: renamed)
        return true
    }

    /// Runs `body`, which changes a build folder, under an exclusive lock unless a running scan holds the folder. Returns
    /// false, without running `body`, when it is in use. A missing folder is not locked.
    public static func whileUnused(_ directory: URL, _ body: () throws -> Void) throws -> Bool {
        guard FileManager.default.fileExists(atPath: directory.path) else {
            try body()
            return true
        }
        guard let descriptor = try CacheLock.tryExclusive(in: directory) else { return false }

        defer { close(descriptor) }
        try body()
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
