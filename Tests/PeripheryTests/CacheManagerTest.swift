import Foundation
@testable import Shared
import XCTest

final class CacheManagerTest: XCTestCase {
    private var root: URL!
    private var cache: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("periphery-cache-test-\(UUID().uuidString)")
        cache = root.appendingPathComponent("cache")
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // Restore permissions so the fake root can always be removed.
        if let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let url as URL in enumerator {
                try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            }
        }
        try fm.removeItem(at: root)
    }

    private func makeDerivedData(_ name: String, ageDays: Int) throws -> URL {
        let dir = cache.appendingPathComponent(name)
        let nested = dir.appendingPathComponent("Index/DataStore")
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4096).write(to: nested.appendingPathComponent("record"))
        let date = Date().addingTimeInterval(-Double(ageDays) * 86400)
        try fm.setAttributes([.modificationDate: date], ofItemAtPath: dir.path)
        return dir
    }

    func testClearCache_removesNestedEntriesAndDirectory() throws {
        _ = try makeDerivedData("DerivedData-a", ageDays: 1)
        _ = try makeDerivedData("DerivedData-b", ageDays: 1)
        let outside = root.appendingPathComponent("outside")
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data([1]).write(to: outside.appendingPathComponent("keep"))
        try fm.createSymbolicLink(at: cache.appendingPathComponent("link"), withDestinationURL: outside)

        try CacheManager.clear(cacheDirectory: cache)

        XCTAssertFalse(fm.fileExists(atPath: cache.path))
        XCTAssertTrue(fm.fileExists(atPath: outside.appendingPathComponent("keep").path))
    }

    func testClearCache_missingDirectoryIsNotAnError() throws {
        try fm.removeItem(at: cache)
        XCTAssertNoThrow(try CacheManager.clear(cacheDirectory: cache))
    }

    func testClearCache_listsEntryThatCannotBeRemoved() throws {
        try XCTSkipIf(getuid() == 0, "root can remove a directory without write permission")
        let locked = try makeDerivedData("DerivedData-locked", ageDays: 1)
        let removable = try makeDerivedData("DerivedData-ok", ageDays: 1)
        // A directory without write permission prevents removing its children.
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.appendingPathComponent("Index").path)

        XCTAssertThrowsError(try CacheManager.clear(cacheDirectory: cache)) { error in
            guard let clearError = error as? CacheClearError else { return XCTFail("unexpected error \(error)") }

            XCTAssertEqual(clearError.failures.map { URL(fileURLWithPath: $0.path).lastPathComponent }, ["DerivedData-locked"])
            XCTAssertTrue(clearError.localizedDescription.contains("DerivedData-locked"))
        }
        XCTAssertFalse(fm.fileExists(atPath: removable.path))
        XCTAssertTrue(fm.fileExists(atPath: locked.path))
    }

    func testEvictionFailure_isReturnedNotThrown() throws {
        try XCTSkipIf(getuid() == 0, "root can remove a directory without write permission")
        let locked = try makeDerivedData("DerivedData-locked", ageDays: 30)
        let removable = try makeDerivedData("DerivedData-removable", ageDays: 30)
        let current = try makeDerivedData("DerivedData-current", ageDays: 1)
        // A directory without write permission prevents removing its children.
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.appendingPathComponent("Index").path)

        let result = CacheManager.refresh(
            directories: [current],
            projectPath: root.path,
            maxAgeDays: 14,
            maxSizeGB: 0,
            cacheDirectory: cache
        )

        XCTAssertEqual(result.evicted.map(\.name), ["DerivedData-removable"])
        XCTAssertEqual(result.failures.map { URL(fileURLWithPath: $0.path).lastPathComponent }, ["DerivedData-locked"])
        XCTAssertFalse(fm.fileExists(atPath: removable.path))
        XCTAssertTrue(fm.fileExists(atPath: current.path))
    }

    func testLockedEntry_isNeverEvicted() throws {
        let lease = CacheLease()
        let busyOrphan = try makeBigDerivedData("DerivedData-busy-orphan", ageDays: 1, kilobytes: 600)
        let busyOld = try makeBigDerivedData("DerivedData-busy-old", ageDays: 30, kilobytes: 600)
        let idle = try makeBigDerivedData("DerivedData-idle", ageDays: 2, kilobytes: 600)
        try CacheManager.recordProject(root.appendingPathComponent("Gone.xcodeproj").path, in: busyOrphan)
        try lease.hold(busyOrphan)
        try lease.hold(busyOld)
        // Another scan holds them while it builds: their dates are the ones of their previous scans.
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-3 * 86400)], ofItemAtPath: busyOrphan.path)
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-30 * 86400)], ofItemAtPath: busyOld.path)

        let result = CacheManager.evictStale(cacheDirectory: cache, maxAgeDays: 14, maxSizeBytes: 1000 << 10, keeping: nil)

        XCTAssertEqual(result.evicted.map(\.name), ["DerivedData-idle"])
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertTrue(fm.fileExists(atPath: busyOrphan.path))
        XCTAssertTrue(fm.fileExists(atPath: busyOld.path))
        XCTAssertFalse(fm.fileExists(atPath: idle.path))
    }

    func testLockedEntry_isEvictedOnceReleased() throws {
        var lease: CacheLease? = CacheLease()
        let old = try makeDerivedData("DerivedData-old", ageDays: 1)
        try lease?.hold(old)
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-30 * 86400)], ofItemAtPath: old.path)
        lease = nil

        let result = CacheManager.evictStale(cacheDirectory: cache, maxAgeDays: 14, keeping: nil)

        XCTAssertEqual(result.evicted.map(\.name), ["DerivedData-old"])
    }

    func testClearCache_reportsEntryHeldByRunningScan() throws {
        let lease = CacheLease()
        let busy = try makeDerivedData("DerivedData-busy", ageDays: 1)
        let idle = try makeDerivedData("DerivedData-idle", ageDays: 1)
        try lease.hold(busy)

        XCTAssertThrowsError(try CacheManager.clear(cacheDirectory: cache)) { error in
            guard let clearError = error as? CacheClearError else { return XCTFail("unexpected error \(error)") }

            XCTAssertEqual(clearError.failures.map { URL(fileURLWithPath: $0.path).lastPathComponent }, ["DerivedData-busy"])
            XCTAssertTrue(clearError.localizedDescription.contains("in use by a running scan"))
        }
        XCTAssertTrue(fm.fileExists(atPath: busy.path))
        XCTAssertFalse(fm.fileExists(atPath: idle.path))
    }

    func testLease_holdsFolderAgainAfterItWasRemoved() throws {
        let lease = CacheLease()
        let folder = cache.appendingPathComponent("DerivedData-rebuilt")
        try lease.hold(folder)
        try fm.removeItem(at: folder)
        try lease.hold(folder)
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-30 * 86400)], ofItemAtPath: folder.path)

        let result = CacheManager.evictStale(cacheDirectory: cache, maxAgeDays: 14, keeping: nil)

        XCTAssertTrue(result.evicted.isEmpty)
        XCTAssertTrue(fm.fileExists(atPath: folder.path))
    }

    func testLease_withoutCreatingLeavesMissingFolderAlone() throws {
        let folder = cache.appendingPathComponent("DerivedData-missing")

        try CacheLease().hold(folder, creating: false)

        XCTAssertFalse(fm.fileExists(atPath: folder.path))
    }

    func testRefresh_sweepsTheCacheAtMostOncePerInterval() throws {
        let fileManager = CountingFileManager()
        let now = Date()
        func refresh(at date: Date) -> CacheRefreshResult {
            CacheManager.refresh(directories: [], projectPath: root.path, maxAgeDays: 14, maxSizeGB: 1, cacheDirectory: cache, now: date, fileManager: fileManager)
        }
        _ = try makeDerivedData("DerivedData-first", ageDays: 30)

        XCTAssertEqual(refresh(at: now).evicted.map(\.name), ["DerivedData-first"])
        XCTAssertGreaterThan(fileManager.reads, 0)

        let second = try makeDerivedData("DerivedData-second", ageDays: 30)
        fileManager.reads = 0
        XCTAssertTrue(refresh(at: now.addingTimeInterval(CacheManager.evictionInterval - 1)).evicted.isEmpty)
        XCTAssertEqual(fileManager.reads, 0)
        XCTAssertTrue(fm.fileExists(atPath: second.path))

        XCTAssertEqual(refresh(at: now.addingTimeInterval(CacheManager.evictionInterval)).evicted.map(\.name), ["DerivedData-second"])
        XCTAssertGreaterThan(fileManager.reads, 0)
    }

    func testEvict_removesStaleKeepsRecentAndCurrent() throws {
        let stale = try makeDerivedData("DerivedData-stale", ageDays: 30)
        let recent = try makeDerivedData("DerivedData-recent", ageDays: 2)
        let current = try makeDerivedData("DerivedData-current", ageDays: 60)
        let unrelated = cache.appendingPathComponent("other")
        try fm.createDirectory(at: unrelated, withIntermediateDirectories: true)
        try fm.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: unrelated.path)

        let evicted = CacheManager.evictStale(cacheDirectory: cache, maxAgeDays: 14, keeping: current).evicted

        XCTAssertEqual(evicted.map(\.name), ["DerivedData-stale"])
        XCTAssertGreaterThan(evicted[0].size, 0)
        XCTAssertFalse(fm.fileExists(atPath: stale.path))
        XCTAssertTrue(fm.fileExists(atPath: recent.path))
        XCTAssertTrue(fm.fileExists(atPath: current.path))
        XCTAssertTrue(fm.fileExists(atPath: unrelated.path))
    }

    func testEvict_zeroDisablesEviction() throws {
        let stale = try makeDerivedData("DerivedData-stale", ageDays: 365)

        let evicted = CacheManager.evictStale(cacheDirectory: cache, maxAgeDays: 0, keeping: nil).evicted

        XCTAssertTrue(evicted.isEmpty)
        XCTAssertTrue(fm.fileExists(atPath: stale.path))
    }

    func testEvict_removesFolderWhoseProjectIsGone() throws {
        let existing = root.appendingPathComponent("App.xcodeproj")
        try fm.createDirectory(at: existing, withIntermediateDirectories: true)
        let orphan = try makeDerivedData("DerivedData-orphan", ageDays: 1)
        let live = try makeDerivedData("DerivedData-live", ageDays: 1)
        try CacheManager.recordProject(root.appendingPathComponent("Gone.xcodeproj").path, in: orphan)
        try CacheManager.recordProject(existing.path, in: live)

        let evicted = CacheManager.evictStale(cacheDirectory: cache, maxAgeDays: 14, keeping: nil).evicted

        XCTAssertEqual(evicted.map(\.name), ["DerivedData-orphan"])
        XCTAssertFalse(fm.fileExists(atPath: orphan.path))
        XCTAssertTrue(fm.fileExists(atPath: live.path))
    }

    func testProjectOnMissingVolume_isNotOrphan() throws {
        let unmounted = try makeDerivedData("DerivedData-unmounted", ageDays: 1)
        let unmountedOld = try makeDerivedData("DerivedData-unmounted-old", ageDays: 30)
        let project = "/Volumes/outskirts-unmounted-\(UUID().uuidString)/App.xcodeproj"
        try CacheManager.recordProject(project, in: unmounted)
        try CacheManager.recordProject(project, in: unmountedOld)
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-30 * 86400)], ofItemAtPath: unmountedOld.path)

        let evicted = CacheManager.evictStale(cacheDirectory: cache, maxAgeDays: 14, keeping: nil).evicted

        XCTAssertEqual(evicted.map(\.name), ["DerivedData-unmounted-old"])
        XCTAssertTrue(fm.fileExists(atPath: unmounted.path))
    }

    func testEvict_folderWithoutSidecarFollowsAgeRule() throws {
        let recent = try makeDerivedData("DerivedData-recent", ageDays: 1)
        let old = try makeDerivedData("DerivedData-old", ageDays: 30)

        let evicted = CacheManager.evictStale(cacheDirectory: cache, maxAgeDays: 14, keeping: nil).evicted

        XCTAssertEqual(evicted.map(\.name), ["DerivedData-old"])
        XCTAssertTrue(fm.fileExists(atPath: recent.path))
        XCTAssertFalse(fm.fileExists(atPath: old.path))
    }

    func testEvict_currentFolderIsKeptEvenWhenItsProjectIsGone() throws {
        let current = try makeDerivedData("DerivedData-current", ageDays: 1)
        try CacheManager.recordProject(root.appendingPathComponent("Gone.xcodeproj").path, in: current)

        let evicted = CacheManager.evictStale(cacheDirectory: cache, maxAgeDays: 14, keeping: current).evicted

        XCTAssertTrue(evicted.isEmpty)
        XCTAssertTrue(fm.fileExists(atPath: current.path))
    }

    func testEvict_orphanEvictionDoesNotDependOnAge() throws {
        let orphan = try makeDerivedData("DerivedData-orphan", ageDays: 1)
        try CacheManager.recordProject(root.appendingPathComponent("Gone.xcodeproj").path, in: orphan)

        let evicted = CacheManager.evictStale(cacheDirectory: cache, maxAgeDays: 0, keeping: nil).evicted

        XCTAssertEqual(evicted.map(\.name), ["DerivedData-orphan"])
        XCTAssertFalse(fm.fileExists(atPath: orphan.path))
    }

    private func makeBigDerivedData(_ name: String, ageDays: Int, kilobytes: Int) throws -> URL {
        let dir = cache.appendingPathComponent(name)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(repeating: 1, count: kilobytes << 10).write(to: dir.appendingPathComponent("blob"))
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-Double(ageDays) * 86400)], ofItemAtPath: dir.path)
        return dir
    }

    func testEvict_sizeCapEvictsLeastRecentlyUsedFirst() throws {
        // 3 folders of 400 KB under a 1000 KB cap: the oldest goes, the two others fit.
        let oldest = try makeBigDerivedData("DerivedData-oldest", ageDays: 3, kilobytes: 400)
        let middle = try makeBigDerivedData("DerivedData-middle", ageDays: 2, kilobytes: 400)
        let newest = try makeBigDerivedData("DerivedData-newest", ageDays: 1, kilobytes: 400)

        let evicted = CacheManager.evictStale(cacheDirectory: cache, maxAgeDays: 14, maxSizeBytes: 1000 << 10, keeping: nil).evicted

        XCTAssertEqual(evicted.map(\.name), ["DerivedData-oldest"])
        XCTAssertFalse(fm.fileExists(atPath: oldest.path))
        XCTAssertTrue(fm.fileExists(atPath: middle.path))
        XCTAssertTrue(fm.fileExists(atPath: newest.path))
    }

    func testEvict_sizeCapNeverEvictsCurrentFolder() throws {
        let current = try makeBigDerivedData("DerivedData-current", ageDays: 10, kilobytes: 600)
        let other = try makeBigDerivedData("DerivedData-other", ageDays: 1, kilobytes: 600)

        let evicted = CacheManager.evictStale(cacheDirectory: cache, maxAgeDays: 14, maxSizeBytes: 1000 << 10, keeping: current).evicted

        XCTAssertEqual(evicted.map(\.name), ["DerivedData-other"])
        XCTAssertTrue(fm.fileExists(atPath: current.path))
        XCTAssertFalse(fm.fileExists(atPath: other.path))
    }

    func testEvict_sizeCapAppliesEvenWhenAgeEvictionIsDisabled() throws {
        let oldest = try makeBigDerivedData("DerivedData-oldest", ageDays: 300, kilobytes: 600)
        let newest = try makeBigDerivedData("DerivedData-newest", ageDays: 200, kilobytes: 600)

        let evicted = CacheManager.evictStale(cacheDirectory: cache, maxAgeDays: 0, maxSizeBytes: 1000 << 10, keeping: nil).evicted

        XCTAssertEqual(evicted.map(\.name), ["DerivedData-oldest"])
        XCTAssertFalse(fm.fileExists(atPath: oldest.path))
        XCTAssertTrue(fm.fileExists(atPath: newest.path))
    }

    func testEvict_zeroSizeCapDisablesLimit() throws {
        let first = try makeBigDerivedData("DerivedData-first", ageDays: 2, kilobytes: 600)
        let second = try makeBigDerivedData("DerivedData-second", ageDays: 1, kilobytes: 600)

        let evicted = CacheManager.evictStale(cacheDirectory: cache, maxAgeDays: 14, maxSizeBytes: 0, keeping: nil).evicted

        XCTAssertTrue(evicted.isEmpty)
        XCTAssertTrue(fm.fileExists(atPath: first.path))
        XCTAssertTrue(fm.fileExists(atPath: second.path))
    }
}

extension CacheManagerTest {
    private func write(_ name: String, in dir: URL) throws {
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(name.utf8).write(to: dir.appendingPathComponent("marker"))
    }

    private func marker(in dir: URL) throws -> String {
        try String(contentsOf: dir.appendingPathComponent("marker"), encoding: .utf8)
    }

    func testCachePath_movesLegacyDirectoryToOutskirtsName() throws {
        let legacy = cache.appendingPathComponent("com.github.tiny-earth-moon.periphery")
        let current = cache.appendingPathComponent("com.github.tiny-earth-moon.outskirts")
        try write("legacy", in: legacy)

        let path = try Constants.cachePath(cachesDirectory: cache)

        XCTAssertEqual(path.string, current.path)
        XCTAssertFalse(fm.fileExists(atPath: legacy.path))
        XCTAssertEqual(try marker(in: current), "legacy")
    }

    func testCachePath_deletesLegacyDirectoryWhenOutskirtsDirectoryExists() throws {
        let legacy = cache.appendingPathComponent("com.github.tiny-earth-moon.periphery")
        let current = cache.appendingPathComponent("com.github.tiny-earth-moon.outskirts")
        try write("legacy", in: legacy)
        try write("current", in: current)

        _ = try Constants.cachePath(cachesDirectory: cache)

        XCTAssertFalse(fm.fileExists(atPath: legacy.path))
        XCTAssertEqual(try marker(in: current), "current")
    }

    func testCachePath_returnsOutskirtsPathWithoutCreatingAnythingWhenNoCacheExists() throws {
        let path = try Constants.cachePath(cachesDirectory: cache)

        XCTAssertEqual(path.string, cache.appendingPathComponent("com.github.tiny-earth-moon.outskirts").path)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: cache.path), [])
    }

    func testClearCache_removesLeftoverLegacyDirectoryToo() throws {
        let legacy = cache.appendingPathComponent("com.github.tiny-earth-moon.periphery")
        let current = cache.appendingPathComponent("com.github.tiny-earth-moon.outskirts")
        try write("current", in: current)
        // Created after the first cachePath() call of the process, as a stale copy from an older release would be.
        _ = try Constants.cachePath(cachesDirectory: cache)
        try write("legacy", in: legacy)

        try CacheManager.clearIncludingLegacy(cachesDirectory: cache)

        XCTAssertFalse(fm.fileExists(atPath: legacy.path))
        XCTAssertFalse(fm.fileExists(atPath: current.path))
    }
}

/// Counts the directory listings: a cache sweep starts with one, and measures only the folders it lists.
private final class CountingFileManager: FileManager, @unchecked Sendable {
    var reads = 0

    override func contentsOfDirectory(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?, options mask: FileManager.DirectoryEnumerationOptions = []) throws -> [URL] {
        reads += 1
        return try super.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: mask)
    }
}
