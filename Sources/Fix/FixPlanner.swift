import Foundation
import SwiftParser
import SystemPackage

/// The git working tree, as far as a fix may touch its files.
public enum WorkingTreeState: Sendable {
    /// Every file may be edited (`--allow-dirty`).
    case ignored
    /// The real path of the top level of the working tree, the real paths of its files with uncommitted changes,
    /// untracked files included, and the real paths of its tracked files: a file that is neither is ignored by git.
    case repository(topLevel: String, uncommitted: Set<String>, tracked: Set<String>)
    /// The project is not in a git repository, so changes could not be reverted.
    case notARepository
}

/// When the index store and the scan read each file: a file modified since then may not match the results.
public struct IndexDates: Sendable {
    let scanStartedAt: Date
    /// When the newest index store unit of each source file was written.
    let unitDates: [FilePath: Date]

    public init(scanStartedAt: Date, unitDates: [FilePath: Date]) {
        self.scanStartedAt = scanStartedAt
        self.unitDates = unitDates
    }

    func isStale(_ file: FilePath, modifiedAt modified: Date) -> Bool {
        guard modified <= scanStartedAt, let unitDate = unitDates[file] else { return true }

        return modified > unitDate
    }
}

/// Turns results into edits of the original buffers, applying the safety rules.
public struct FixPlanner {
    /// The real path of the project root: without a git working tree to confine the edits, no file outside it is edited.
    let projectRoot: String
    let workingTree: WorkingTreeState
    /// Nil skips the check, for buffers that were not indexed.
    let indexDates: IndexDates?
    let isIndexExcluded: (FilePath) -> Bool

    public init(projectRoot: FilePath, workingTree: WorkingTreeState, indexDates: IndexDates?, isIndexExcluded: @escaping (FilePath) -> Bool) {
        self.projectRoot = RealPath.resolve(projectRoot.string)
        self.workingTree = workingTree
        self.indexDates = indexDates
        self.isIndexExcluded = isIndexExcluded
    }

    public func plan(_ targets: [FixTarget]) -> FixPlan {
        var plan = FixPlan()
        let uniqueTargets = Array(Set(targets))
        let targetsByFile = Dictionary(grouping: uniqueTargets, by: \.file)

        for file in targetsByFile.keys.sorted(by: { $0.string < $1.string }) {
            let fileTargets = targetsByFile[file, default: []].sorted { ($0.line, $0.column, $0.rule.rawValue, $0.name) < ($1.line, $1.column, $1.rule.rawValue, $1.name) }
            planFile(file, targets: fileTargets, into: &plan)
        }
        return plan
    }

    // MARK: - Private

    private func planFile(_ file: FilePath, targets: [FixTarget], into plan: inout FixPlan) {
        func skipAll(_ reason: SkipReason) {
            plan.skipped += targets.map { FixPlan.Skip(target: $0, reason: reason) }
        }

        if let reason = fileRefusal(file) {
            return skipAll(reason)
        }
        guard let data = FileManager.default.contents(atPath: file.string) else { return skipAll(.unreadableFile) }

        let bytes = [UInt8](data)
        if GeneratedFile.isGenerated(path: file, contents: bytes) {
            return skipAll(.generatedFile)
        }

        // The edits are offsets of the bytes on disk, so the bytes themselves are parsed: decoding them first would
        // drop a byte order mark and shift every offset.
        let tree = bytes.withUnsafeBufferPointer { Parser.parse(source: $0) }
        guard tree.totalLength.utf8Length == bytes.count else { return skipAll(.unreadableFile) }

        let source = ParsedSource(path: file.string, bytes: bytes, tree: tree)
        let builder = EditBuilder(source: source)
        let ignoredParameterNames = superfluousParameterIgnores(in: targets)

        var editsByOwner: [Int: [SourceEdit]] = [:]
        for (index, target) in targets.enumerated() {
            if target.hasLocationOverride {
                plan.skipped.append(.init(target: target, reason: .locationOverride))
                continue
            }

            let names = ignoredParameterNames[TargetPosition(target)] ?? []
            switch builder.edits(for: target, ignoredParameterNames: names) {
            case let .success(edits):
                editsByOwner[index] = edits
            case let .failure(reason):
                plan.skipped.append(.init(target: target, reason: reason))
            }
        }

        let resolution = EditResolution(editsByOwner)
        for index in editsByOwner.keys.sorted() {
            if resolution.refusedOwners.contains(index) {
                plan.skipped.append(.init(target: targets[index], reason: .overlappingEdit))
            } else {
                plan.applied.append(targets[index])
            }
        }

        let fixed = resolution.apply(to: bytes)
        if fixed != bytes {
            plan.changes.append(.init(path: file, realPath: RealPath.resolve(file.string), original: bytes, fixed: fixed))
        }
    }

    private func fileRefusal(_ file: FilePath) -> SkipReason? {
        if isIndexExcluded(file) {
            return .indexExcluded
        }
        if GeneratedFile.isGenerated(path: file) {
            return .generatedFile
        }

        var status = stat()
        guard lstat(file.string, &status) == 0 else { return .unreadableFile }

        if (status.st_mode & S_IFMT) == S_IFLNK {
            return .symbolicLink
        }

        if let reason = workingTreeRefusal(file) {
            return reason
        }

        if let indexDates, indexDates.isStale(file, modifiedAt: modificationDate(of: status)) {
            return .changedSinceIndexing
        }
        return nil
    }

    private func modificationDate(of status: stat) -> Date {
        #if os(Linux)
            let time = status.st_mtim
        #else
            let time = status.st_mtimespec
        #endif
        return Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1_000_000_000)
    }

    /// Only the files that git can restore are edited: tracked by the working tree itself, not by a submodule or a
    /// nested repository, not ignored, and without uncommitted changes. Without a working tree, the real path, which follows every
    /// linked directory, must be in the project root.
    private func workingTreeRefusal(_ file: FilePath) -> SkipReason? {
        switch workingTree {
        case .ignored:
            return RealPath.resolve(file.string).hasPrefix(projectRoot + "/") ? nil : .outsideProject
        case .notARepository:
            return RealPath.resolve(file.string).hasPrefix(projectRoot + "/") ? .notInGitRepository : .outsideProject
        case let .repository(topLevel, uncommitted, tracked):
            let realPath = RealPath.resolve(file.string)
            guard realPath.hasPrefix(topLevel + "/") else { return .outsideRepository }

            let directory = FilePath(realPath).removingLastComponent()
            do {
                guard try GitWorkingTree.topLevel(of: directory) == topLevel else { return .nestedRepository }
            } catch {
                return .gitFailed("\(error)")
            }

            if uncommitted.contains(realPath) {
                return .uncommittedChanges
            }
            return tracked.contains(realPath) ? nil : .ignoredByGit
        }
    }

    /// The names of the parameters whose `ignore:parameters` comment is superfluous, by function position.
    private func superfluousParameterIgnores(in targets: [FixTarget]) -> [TargetPosition: Set<String>] {
        targets
            .filter { $0.rule == .superfluousIgnore && $0.kind == .varParameter }
            .reduce(into: [:]) { result, target in
                result[TargetPosition(target), default: []].insert(target.name)
            }
    }
}

private struct TargetPosition: Hashable {
    let line: Int
    let column: Int

    init(_ target: FixTarget) {
        line = target.line
        column = target.column
    }
}

/// The edits of a fix run, and the results that were applied or skipped.
public struct FixPlan {
    public struct Change {
        let path: FilePath
        /// The real path of the file when the edits were planned: the file is written there only.
        let realPath: String
        let original: [UInt8]
        let fixed: [UInt8]
    }

    struct Skip {
        let target: FixTarget
        let reason: SkipReason
    }

    public internal(set) var changes: [Change] = []
    internal(set) var applied: [FixTarget] = []
    internal(set) var skipped: [Skip] = []

    /// The unified diff of every change, with paths relative to the given directory.
    public func diff(relativeTo root: FilePath) -> String {
        changes.map { change in
            let path = change.path.relativePath(from: root)
            guard let old = String(bytes: change.original, encoding: .utf8),
                  let new = String(bytes: change.fixed, encoding: .utf8)
            else { return "Binary files a/\(path) and b/\(path) differ\n" }

            return UnifiedDiff.diff(old: old, new: new, oldPath: "a/\(path)", newPath: "b/\(path)")
        }.joined()
    }

    /// A short summary of the applied and skipped results, with the reason of each skip.
    public func summary(relativeTo root: FilePath, applying: Bool) -> String {
        let verb = applying ? "Applied" : "Would apply"
        var lines = ["\(verb) \(applied.count) fix\(applied.count == 1 ? "" : "es") in \(changes.count) file\(changes.count == 1 ? "" : "s"), skipped \(skipped.count)."]

        lines += ruleBreakdown()

        let sortedSkips = skipped.sorted { ($0.target.file.string, $0.target.line, $0.target.column) < ($1.target.file.string, $1.target.line, $1.target.column) }
        for skip in sortedSkips {
            let target = skip.target
            let location = "\(target.file.relativePath(from: root)):\(target.line):\(target.column)"
            lines.append("  skipped \(target.rule.rawValue) '\(target.name)' at \(location): \(skip.reason)")
        }
        return lines.joined(separator: "\n")
    }

    /// One line per rule, in the order of `FixRule`: the applied count, then the skipped count with each reason.
    private func ruleBreakdown() -> [String] {
        FixRule.allCases.compactMap { rule in
            let appliedCount = applied.count { $0.rule == rule }
            let skips = skipped.filter { $0.target.rule == rule }
            guard appliedCount > 0 || !skips.isEmpty else { return nil }

            var line = "  \(rule.rawValue): \(appliedCount)"
            if !skips.isEmpty {
                let reasons = Dictionary(grouping: skips, by: { $0.reason.description })
                    .map { (reason: $0.key, count: $0.value.count) }
                    .sorted { ($1.count, $0.reason) < ($0.count, $1.reason) }
                    .map { "\($0.reason) \($0.count)" }
                line += ", skipped \(skips.count) (\(reasons.joined(separator: ", ")))"
            }
            return line
        }
    }
}

public extension FilePath {
    /// The path from the root, with `..` components for a path outside it, so that a diff header stays usable.
    func relativePath(from root: FilePath) -> String {
        guard isAbsolute, root.isAbsolute else { return string }

        let rootComponents = Array(root.lexicallyNormalized().components)
        let components = Array(lexicallyNormalized().components)
        let common = zip(rootComponents, components).prefix { $0 == $1 }.count
        let parts = Array(repeating: "..", count: rootComponents.count - common) + components[common...].map(\.string)
        return parts.joined(separator: "/")
    }
}

enum RealPath {
    static func resolve(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }

        defer { free(resolved) }
        return String(cString: resolved)
    }
}
