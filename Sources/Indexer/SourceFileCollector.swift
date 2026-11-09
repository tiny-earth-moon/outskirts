import Configuration
import Foundation
import IndexStore
import Logger
import Shared
import SourceGraph
import SystemPackage

public struct SourceFileCollector {
    private typealias CollectedUnit = (FilePath, FilePath, IndexStore, UnitReader, String, Date?, Bool)

    private struct StoreUnits {
        let path: FilePath
        let collected: [CollectedUnit]
        let unreadable: [String]
        let hasTargetExcludedUnit: Bool
    }

    private enum UnitOutcome {
        case skipped
        case targetExcluded
        case collected(CollectedUnit)

        var collectedUnit: CollectedUnit? {
            guard case let .collected(unit) = self else { return nil }

            return unit
        }

        var isTargetExcluded: Bool {
            guard case .targetExcluded = self else { return false }

            return true
        }
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

    /// The source files to index, and the existing main files of the units that `index_exclude` leaves out.
    public func collectWithIndexExcludedFiles() throws -> (sourceFiles: [SourceFile: [IndexUnit]], indexExcludedFiles: Set<FilePath>, unreadableUnits: [String]) {
        let excludedTargets = excludedTestTargets.union(configuration.excludeTargets)
        let currentFilePath = FilePath.current

        let storeResults = try JobPool(jobs: Array(indexStorePaths))
            .flatMap { indexStorePath -> [StoreUnits] in
                logger.debug("Reading \(indexStorePath)")
                let indexStore = try IndexStore(path: indexStorePath.string)
                let (units, unreadable) = indexStore.readUnits()

                let unitsDirectory = indexStorePath.appending("v5/units")

                // Each unit costs a few file system calls: the units of a store are classified concurrently.
                let outcomes = Concurrently.map(units.filter { !$0.isSystem }) { unit -> UnitOutcome in
                    let filePath = unit.mainFile

                    guard !filePath.isEmpty else {
                        return .skipped
                    }

                    let file = FilePath.makeAbsolute(filePath, relativeTo: currentFilePath)

                    if !isExcluded(file) {
                        guard file.exists else {
                            logger.debug("Source file does not exist: \(file.string)")
                            return .skipped
                        }

                        if excludedTargets.contains(unit.moduleName) {
                            return .targetExcluded
                        }

                        return .collected((file, indexStorePath, indexStore, unit, unit.moduleName, Self.modificationDate(of: unitsDirectory.appending(unit.name)), false))
                    }

                    return file.exists ? .collected((file, indexStorePath, indexStore, unit, unit.moduleName, nil, true)) : .skipped
                }

                return [StoreUnits(
                    path: indexStorePath,
                    collected: outcomes.compactMap(\.collectedUnit),
                    unreadable: unreadable,
                    hasTargetExcludedUnit: outcomes.contains(where: \.isTargetExcluded)
                )]
            }
        let unreadableUnits = storeResults.reduce(into: [FilePath: Set<String>]()) { $0[$1.path] = Set($1.unreadable) }
        if let warning = try Self.unreadableUnitsWarning(unreadableUnits, relativeTo: currentFilePath, strict: configuration.strictIndex) {
            logger.warn(warning)
        }

        let collectedUnits = storeResults.flatMap(\.collected)

        // Without expected files (a generic project config), nothing else notices a store with no usable unit, and
        // the scan would report "no unused code". Excluding every unit with `exclude_targets` is the user's choice.
        if collectedUnits.isEmpty, !storeResults.contains(where: \.hasTargetExcludedUnit) {
            throw PeripheryError.emptyIndexStore(indexStorePaths: indexStorePaths.map(\.string).sorted())
        }

        let indexExcludedFiles = collectedUnits.filter(\.6).mapSet(\.0)
        let collected = collectedUnits
            .filter { !$0.6 }
            .reduce(into: [FilePath: [(FilePath, IndexStore, UnitReader, String, Date?)]]()) { result, tuple in
                let (file, indexStorePath, indexStore, unit, module, date, _) = tuple
                result[file, default: []].append((indexStorePath, indexStore, unit, module, date))
            }

        var sourceFiles: [SourceFile: [IndexUnit]] = [:]
        var outdatedFiles: [FilePath: Set<FilePath>] = [:]
        let collectedFiles = Array(collected)
        let sourceModificationDates = Concurrently.map(collectedFiles) { Self.modificationDate(of: $0.key) }

        for ((file, allTuples), sourceModificationDate) in zip(collectedFiles, sourceModificationDates) {
            let tuples = Self.currentUnits(
                allTuples,
                sourceModificationDate: sourceModificationDate,
                module: \.3,
                modificationDate: \.4
            )
            let modules = tuples.compactMapSet { $0.3 }
            let variant = { (tuple: (FilePath, IndexStore, UnitReader, String, Date?)) in
                IndexVariant(triple: tuple.2.target, isOptimized: !tuple.2.isDebugCompilation)
            }
            let currentVariants = Self.upToDateUnits(tuples, sourceModificationDate: sourceModificationDate, modificationDate: \.4).mapSet(variant)
            let sourceFile = SourceFile(path: file, modules: modules, variants: tuples.mapSet(variant), currentVariants: currentVariants)
            sourceFiles[sourceFile] = tuples.map { IndexUnit(store: $0.1, unit: $0.2, modificationDate: $0.4) }

            for tuple in Self.outdatedUnits(tuples, sourceModificationDate: sourceModificationDate, modificationDate: \.4) {
                outdatedFiles[tuple.0, default: []].insert(file)
            }
        }

        let variants = sourceFiles.keys.reduce(into: Set<IndexVariant>()) { $0.formUnion($1.variants) }
        if !variants.isEmpty {
            logger.debug("Index variants: \(variants.sorted().map(\.description).joined(separator: ", "))")
        }

        if let warning = try Self.outdatedIndexWarning(outdatedFiles, relativeTo: currentFilePath, strict: configuration.strictIndex) {
            logger.warn(warning)
        }

        return (sourceFiles, indexExcludedFiles, unreadableUnits.values.flatMap(\.self).sorted())
    }

    /// A unit written before its source file was last modified describes an older version of the file, e.g. a unit
    /// left in the store by a build whose output paths have since changed (a renamed package, a restored CI cache).
    /// Such units are dropped when the same module has a unit written since, which describes the current file;
    /// otherwise they are kept, as they are the only index data available for the file.
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

    /// The units written since the source file was last modified, every unit when a date is unknown: an older unit
    /// misses the code added since, so it cannot tell that the `#if` clauses its build compiled are in the index.
    static func upToDateUnits<Unit>(
        _ units: [Unit],
        sourceModificationDate: Date?,
        modificationDate: (Unit) -> Date?
    ) -> [Unit] {
        units.filter { unit in
            guard let sourceModificationDate, let date = modificationDate(unit) else { return true }

            return date >= sourceModificationDate
        }
    }

    /// The units kept by `currentUnits` that were written before the source file was last modified: they are the
    /// only index data of their module for the file, yet describe an older version of it.
    static func outdatedUnits<Unit>(
        _ units: [Unit],
        sourceModificationDate: Date?,
        modificationDate: (Unit) -> Date?
    ) -> [Unit] {
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

    private func isExcluded(_ file: FilePath) -> Bool {
        configuration.isIndexExcluded(file)
    }
}
