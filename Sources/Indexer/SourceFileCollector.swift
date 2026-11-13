import Configuration
import Foundation
@preconcurrency import IndexStore
import Logger
import Shared
import SourceGraph
import SystemPackage

public struct SourceFileCollector {
    private struct StoreUnits {
        let path: FilePath
        let collected: [(FilePath, FilePath, IndexStore, UnitReader, String, Date?)]
        let unreadable: [String]
        let hasIgnoredUnit: Bool
        /// With `index_built_from`: the main files of the units whose source file no longer exists, and of all units.
        let missing: [FilePath]
        let mainFiles: [FilePath]
    }

    private let indexStorePaths: Set<FilePath>
    private let excludedTestTargets: Set<String>
    private let logger: ContextualLogger
    private let configuration: Configuration

    public init(
        indexStorePaths: Set<FilePath>,
        excludedTestTargets: Set<String>,
        logger: ContextualLogger,
        configuration: Configuration
    ) {
        self.indexStorePaths = indexStorePaths
        self.excludedTestTargets = excludedTestTargets
        self.logger = logger
        self.configuration = configuration
    }

    /// The source files to index, and the names of the index store units that cannot be read.
    public func collect() throws -> (sourceFiles: [SourceFile: [IndexUnit]], unreadableUnits: [String]) {
        let excludedTargets = excludedTestTargets.union(configuration.excludeTargets)
        let currentFilePath = FilePath.current
        let logger = logger
        // `Configuration` is not `Sendable`: the jobs only read it, and nothing mutates it while they run.
        nonisolated(unsafe) let configuration = configuration
        let projectRoot = FilePath.makeAbsolute(configuration.projectRoot, relativeTo: currentFilePath)
        let freshness = try configuration.indexBuiltFrom.map { try GitIndexFreshness.read(revision: $0, in: projectRoot) }
        let judgesByGit = freshness != nil

        let storeResults = try JobPool(jobs: Array(indexStorePaths))
            .flatMap { indexStorePath -> [StoreUnits] in
                logger.debug("Reading \(indexStorePath)")
                let indexStore = try IndexStore(path: indexStorePath.string)
                let (units, unreadable) = indexStore.readUnits()

                let unitsDirectory = indexStorePath.appending("v5/units")
                var hasIgnoredUnit = false
                var missing: [FilePath] = []
                var mainFiles: [FilePath] = []

                let collected = units.filter { !$0.isSystem }.compactMap { unit -> (FilePath, FilePath, IndexStore, UnitReader, String, Date?)? in
                    let filePath = unit.mainFile

                    guard !filePath.isEmpty else {
                        return nil
                    }

                    let file = FilePath.makeAbsolute(filePath, relativeTo: currentFilePath)
                    if judgesByGit {
                        mainFiles.append(file)
                    }

                    if !configuration.isIndexExcluded(file) {
                        guard file.exists else {
                            logger.debug("Source file does not exist: \(file.string)")
                            if judgesByGit, !excludedTargets.contains(unit.moduleName) {
                                missing.append(file)
                            }
                            return nil
                        }

                        if excludedTargets.contains(unit.moduleName) {
                            hasIgnoredUnit = true
                            return nil
                        }

                        return (file, indexStorePath, indexStore, unit, unit.moduleName, Self.modificationDate(of: unitsDirectory.appending(unit.name)))
                    }

                    if file.exists {
                        hasIgnoredUnit = true
                    }

                    return nil
                }

                return [StoreUnits(path: indexStorePath, collected: collected, unreadable: unreadable, hasIgnoredUnit: hasIgnoredUnit, missing: missing, mainFiles: mainFiles)]
            }
        let unreadableUnits = storeResults.reduce(into: [FilePath: Set<String>]()) { $0[$1.path] = Set($1.unreadable) }
        if let warning = try Self.unreadableUnitsWarning(unreadableUnits, relativeTo: currentFilePath, strict: configuration.strictIndex) {
            logger.warn(warning)
        }

        let collectedUnits = storeResults.flatMap(\.collected)

        // Without expected files (a generic project config), nothing else notices a store with no usable unit, and
        // the scan would report "no unused code". Leaving every unit out with `exclude_targets` or `index_exclude` is
        // the user's choice.
        if collectedUnits.isEmpty, !storeResults.contains(where: \.hasIgnoredUnit) {
            throw PeripheryError.emptyIndexStore(indexStorePaths: indexStorePaths.map(\.string).sorted())
        }

        let collected = collectedUnits
            .reduce(into: [FilePath: [(FilePath, IndexStore, UnitReader, String, Date?)]]()) { result, tuple in
                let (file, indexStorePath, indexStore, unit, module, date) = tuple
                result[file, default: []].append((indexStorePath, indexStore, unit, module, date))
            }

        var sourceFiles: [SourceFile: [IndexUnit]] = [:]
        var outdatedFiles: [FilePath: Set<FilePath>] = [:]
        var changedFiles: [FilePath: Set<FilePath>] = [:]
        var filesJudgedByDate = 0

        for (file, allTuples) in collected {
            let sourceModificationDate = Self.modificationDate(of: file)
            let tuples = Self.currentUnits(
                allTuples,
                sourceModificationDate: sourceModificationDate,
                module: \.3,
                modificationDate: \.4
            )
            let modules = tuples.compactMapSet { $0.3 }
            let sourceFile = SourceFile(path: file, modules: modules)
            sourceFiles[sourceFile] = tuples.map { IndexUnit(store: $0.1, unit: $0.2) }

            let changedSinceRevision = freshness?.hasChanged(file)
            if changedSinceRevision == nil {
                filesJudgedByDate += 1
            }

            for tuple in Self.outdatedUnits(tuples, sourceModificationDate: sourceModificationDate, changedSinceRevision: changedSinceRevision, modificationDate: \.4) {
                if changedSinceRevision == nil {
                    outdatedFiles[tuple.0, default: []].insert(file)
                } else {
                    changedFiles[tuple.0, default: []].insert(file)
                }
            }
        }

        if let warning = try Self.outdatedIndexWarning(outdatedFiles, relativeTo: currentFilePath, strict: configuration.strictIndex) {
            logger.warn(warning)
        }

        if let freshness {
            try warnAboutChanges(since: freshness, in: storeResults, changedFiles: changedFiles, filesJudgedByDate: filesJudgedByDate, projectRoot: projectRoot)
        }

        return (sourceFiles, unreadableUnits.values.flatMap(\.self).sorted())
    }

    /// A unit written before its source file was last modified describes an older version of the file, e.g. a unit
    /// left in the store by a build whose output paths have since changed (a renamed package, a restored CI cache).
    /// Such units are dropped when the same module has a unit written since, which describes the current file;
    /// otherwise they are kept, as they are the only index data available for the file. With `index_built_from` too, as
    /// git cannot tell which of the units was written from the revision: only whether the file is outdated changes.
    static func currentUnits<Unit>(
        _ units: [Unit],
        sourceModificationDate: Date?,
        module: (Unit) -> String,
        modificationDate: (Unit) -> Date?
    ) -> [Unit] {
        guard let sourceModificationDate else { return units }

        func isCurrent(_ unit: Unit) -> Bool {
            guard let date = modificationDate(unit) else { return false }

            return date >= sourceModificationDate
        }

        let modulesWithCurrentUnit = Set(units.filter(isCurrent).map(module))

        return units.filter { unit in
            guard modulesWithCurrentUnit.contains(module(unit)), modificationDate(unit) != nil else { return true }

            return isCurrent(unit)
        }
    }

    /// The units kept by `currentUnits` that were written before the source file was last modified: they are the
    /// only index data of their module for the file, yet describe an older version of it. With `index_built_from`,
    /// git judges the files it knows instead (`changedSinceRevision` is non-nil): every unit of a file changed since
    /// the revision is outdated, and none of an unchanged file, whatever the dates.
    static func outdatedUnits<Unit>(
        _ units: [Unit],
        sourceModificationDate: Date?,
        changedSinceRevision: Bool? = nil,
        modificationDate: (Unit) -> Date?
    ) -> [Unit] {
        if let changedSinceRevision {
            return changedSinceRevision ? units : []
        }

        guard let sourceModificationDate else { return [] }

        return units.filter { unit in
            guard let date = modificationDate(unit) else { return false }

            return date < sourceModificationDate
        }
    }

    /// A single warning for the scan, naming each index store with its number of outdated files and a few of them.
    static func outdatedIndexWarning(_ outdatedFiles: [FilePath: Set<FilePath>], relativeTo base: FilePath, examples: Int = 3) -> String? {
        let stores = outdatedFiles
            .filter { !$0.value.isEmpty }
            .sorted { ($1.value.count, $0.key.string) < ($0.value.count, $1.key.string) }
        let count = stores.reduce(0) { $0 + $1.value.count }

        guard count > 0 else { return nil }

        func display(_ path: FilePath) -> String {
            Self.display(path, relativeTo: base)
        }

        func list(_ files: Set<FilePath>) -> String {
            Self.list(files.map(display), examples: examples)
        }

        let subject = count == 1 ? "1 source file is newer than its index data" : "\(count) source files are newer than their index data"
        let location = if stores.count == 1, let (store, files) = stores.first {
            " in \(display(store)): \(list(files))"
        } else {
            ": " + stores.map { "\($0.value.count) in \(display($0.key)) (\(list($0.value)))" }.joined(separator: ", ")
        }
        let pronoun = count == 1 ? "it" : "them"

        return "\(subject)\(location). Results in \(pronoun) may be at the wrong lines or missing: rebuild the project before scanning, or pass '--clean-build' to start from an empty index store."
    }

    /// The warning to print for the outdated files, if any; with `strict_index`, the scan fails instead.
    static func outdatedIndexWarning(_ outdatedFiles: [FilePath: Set<FilePath>], relativeTo base: FilePath, strict: Bool) throws -> String? {
        guard let warning = outdatedIndexWarning(outdatedFiles, relativeTo: base) else { return nil }

        if strict {
            throw PeripheryError.outdatedIndexData(message: warning + " Failing as '--strict-index' is set.")
        }

        return warning
    }

    /// With `index_built_from`, a single warning for the files changed since the revision: those described by units of
    /// each index store, and those no unit accounts for (added sources, and the other files the scan reads).
    static func changedSinceRevisionWarning(
        _ changedFiles: [FilePath: Set<FilePath>],
        unindexed: Set<FilePath>,
        revision: String,
        relativeTo base: FilePath,
        examples: Int = 3
    ) -> String? {
        var groups = changedFiles
            .filter { !$0.value.isEmpty }
            .sorted { ($1.value.count, $0.key.string) < ($0.value.count, $1.key.string) }
            .map { (label: "in \(display($0.key, relativeTo: base))", files: $0.value) }
        if !unindexed.isEmpty {
            groups.append((label: "not in the index", files: unindexed))
        }
        let count = groups.reduce(0) { $0 + $1.files.count }

        guard count > 0 else { return nil }

        func list(_ files: Set<FilePath>) -> String {
            Self.list(files.map { display($0, relativeTo: base) }, examples: examples)
        }

        let subject = count == 1 ? "1 file changed" : "\(count) files changed"
        let location = if groups.count == 1, let (label, files) = groups.first {
            ", \(label): \(list(files))"
        } else {
            ": " + groups.map { "\($0.files.count) \($0.label) (\(list($0.files)))" }.joined(separator: ", ")
        }

        return "\(subject) since \(revision), the revision the index was built from\(location). Results may be at the wrong lines or missing: rebuild the project before scanning, or pass '--clean-build' to start from an empty index store."
    }

    /// The warning to print for the files changed since the revision, if any; with `strict_index`, the scan fails instead.
    static func changedSinceRevisionWarning(
        _ changedFiles: [FilePath: Set<FilePath>],
        unindexed: Set<FilePath>,
        revision: String,
        relativeTo base: FilePath,
        strict: Bool
    ) throws -> String? {
        guard let warning = changedSinceRevisionWarning(changedFiles, unindexed: unindexed, revision: revision, relativeTo: base) else { return nil }

        if strict {
            throw PeripheryError.outdatedIndexData(message: warning + " Failing as '--strict-index' is set.")
        }

        return warning
    }

    /// A single warning for the scan, naming each index store with its number of unreadable units and a few of them.
    /// The source files these units describe are missing from the scan, so their declarations are not indexed and
    /// whatever only they reference is reported as unused.
    static func unreadableUnitsWarning(_ unreadableUnits: [FilePath: Set<String>], relativeTo base: FilePath, examples: Int = 3) -> String? {
        let stores = unreadableUnits
            .filter { !$0.value.isEmpty }
            .sorted { ($1.value.count, $0.key.string) < ($0.value.count, $1.key.string) }
        let count = stores.reduce(0) { $0 + $1.value.count }

        guard count > 0 else { return nil }

        let subject = count == 1 ? "1 index store unit cannot be read" : "\(count) index store units cannot be read"
        let location = if stores.count == 1, let (store, names) = stores.first {
            " in \(display(store, relativeTo: base)): \(list(Array(names), examples: examples))"
        } else {
            ": " + stores.map { "\($0.value.count) in \(display($0.key, relativeTo: base)) (\(list(Array($0.value), examples: examples)))" }.joined(separator: ", ")
        }
        let files = count == 1 ? "The source file it describes is" : "The source files they describe are"

        return "\(subject)\(location). \(files) left out of the scan, so declarations used only there may be reported as unused: rebuild the project before scanning, or pass '--clean-build' to start from an empty index store."
    }

    /// The warning to print for the unreadable units, if any; with `strict_index`, the scan fails instead.
    static func unreadableUnitsWarning(_ unreadableUnits: [FilePath: Set<String>], relativeTo base: FilePath, strict: Bool) throws -> String? {
        guard let warning = unreadableUnitsWarning(unreadableUnits, relativeTo: base) else { return nil }

        if strict {
            throw PeripheryError.unreadableIndexUnits(message: warning + " Failing as '--strict-index' is set.")
        }

        return warning
    }

    // MARK: - Private

    /// With `index_built_from`: warns about the files changed since the revision, or fails with `strict_index`.
    private func warnAboutChanges(
        since freshness: GitIndexFreshness,
        in storeResults: [StoreUnits],
        changedFiles: [FilePath: Set<FilePath>],
        filesJudgedByDate: Int,
        projectRoot: FilePath
    ) throws {
        var changedFiles = changedFiles
        for store in storeResults {
            for file in store.missing where freshness.hasChanged(file) == true {
                changedFiles[store.path, default: []].insert(file)
            }
        }

        let unindexed = freshness.unindexedChanges(
            indexed: Set(storeResults.flatMap(\.mainFiles)),
            in: projectRoot,
            isExcluded: configuration.isIndexExcluded
        )
        logger.debug("index freshness: git \(freshness.revision), \(freshness.changed.count) files changed, \(filesJudgedByDate) files outside the repository checked by date")

        if let warning = try Self.changedSinceRevisionWarning(
            changedFiles,
            unindexed: unindexed,
            revision: freshness.revision,
            relativeTo: FilePath.current,
            strict: configuration.strictIndex
        ) {
            logger.warn(warning)
        }
    }

    private static func display(_ path: FilePath, relativeTo base: FilePath) -> String {
        path.starts(with: base) ? path.relativeTo(base).string : path.string
    }

    private static func list(_ names: [String], examples: Int) -> String {
        let names = names.sorted()
        let shown = names.prefix(examples).joined(separator: ", ")

        return names.count > examples ? "\(shown) and \(names.count - examples) more" : shown
    }

    private static func modificationDate(of path: FilePath) -> Date? {
        do {
            return try FileManager.default.attributesOfItem(atPath: path.string)[.modificationDate] as? Date
        } catch {
            return nil
        }
    }
}
