import Foundation
import PeripheryKit
import SystemPackage

/// Turns the unused String Catalog keys of a scan into whole-file changes, applying the safety rules.
public struct FixPlanner {
    /// The real path of the project root: without a git working tree to confine the changes, no file outside it is
    /// written.
    let projectRoot: String
    let workingTree: WorkingTreeState
    /// When the scan started, before it read any catalog: a catalog modified since may not match the results. Nil
    /// skips the check.
    let scanStartedAt: Date?

    public init(projectRoot: FilePath, workingTree: WorkingTreeState, scanStartedAt: Date?) {
        self.projectRoot = RealPath.resolve(projectRoot.string)
        self.workingTree = workingTree
        self.scanStartedAt = scanStartedAt
    }

    /// The unused keys of the results, by catalog: the only results the fix removes.
    public static func unusedCatalogKeys(in results: [ScanResult]) -> [FilePath: Set<String>] {
        results.reduce(into: [:]) { keys, result in
            guard let unused = result.unusedLocalizedStringKey else { return }

            keys[unused.catalog, default: []].insert(unused.key)
        }
    }

    public func plan(_ keysByCatalog: [FilePath: Set<String>]) -> FixPlan {
        var plan = FixPlan()
        for (file, keys) in keysByCatalog.sorted(by: { $0.key.string < $1.key.string }) where !keys.isEmpty {
            do {
                try plan.changes.append(change(of: file, removing: keys))
            } catch let reason as SkipReason {
                plan.skipped.append(.init(path: file, keys: keys, reason: reason))
            } catch let error as XCStringsKeyRemovalError {
                plan.skipped.append(.init(path: file, keys: keys, reason: .catalogRefused(error)))
            } catch {
                plan.skipped.append(.init(path: file, keys: keys, reason: .unreadableFile))
            }
        }
        return plan
    }

    // MARK: - Private

    private func change(of file: FilePath, removing keys: Set<String>) throws -> FixPlan.Change {
        var status = stat()
        guard lstat(file.string, &status) == 0 else { throw SkipReason.unreadableFile }

        if (status.st_mode & S_IFMT) == S_IFLNK {
            throw SkipReason.symbolicLink
        }
        let realPath = RealPath.resolve(file.string)
        try checkWorkingTree(realPath)
        if let scanStartedAt, modificationDate(of: status) > scanStartedAt {
            throw SkipReason.changedSinceScan
        }

        let original = try [UInt8](Data(contentsOf: URL(fileURLWithPath: file.string)))
        let fixed = try XCStringsKeyRemover.removing(keys, from: original)
        return FixPlan.Change(path: file, realPath: realPath, original: original, fixed: fixed, removedKeys: keys)
    }

    private func modificationDate(of status: stat) -> Date {
        #if os(Linux)
            let time = status.st_mtim
        #else
            let time = status.st_mtimespec
        #endif
        return Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1_000_000_000)
    }

    /// Only the files git can restore are written: tracked by the working tree itself and without uncommitted
    /// changes. Without a working tree, the real path, which follows every linked directory, must be in the project
    /// root.
    private func checkWorkingTree(_ realPath: String) throws {
        switch workingTree {
        case .ignored:
            guard realPath.hasPrefix(projectRoot + "/") else { throw SkipReason.outsideProject }

        case .notARepository:
            throw realPath.hasPrefix(projectRoot + "/") ? SkipReason.notInGitRepository : SkipReason.outsideProject

        case let .repository(topLevel, uncommitted, tracked):
            guard realPath.hasPrefix(topLevel + "/") else { throw SkipReason.outsideRepository }
            guard !uncommitted.contains(realPath) else { throw SkipReason.uncommittedChanges }
            guard tracked.contains(realPath) else { throw SkipReason.notTrackedByGit }
        }
    }
}

enum RealPath {
    static func resolve(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }

        defer { free(resolved) }
        return String(cString: resolved)
    }
}
