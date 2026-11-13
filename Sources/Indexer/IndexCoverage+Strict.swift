import Foundation
import Shared
import SystemPackage

/// `strict_index_coverage`: the coverage of each scanned target is judged per platform, from the module and target
/// triple of the units of its files. A file shared by an iOS and a macOS target has units of both platforms only
/// when both were built, so units of the file alone do not prove that a target was built.
extension IndexCoverage {
    /// The module and platform of an index unit.
    struct IndexedUnit: Hashable {
        let module: String
        let platform: IndexPlatform?
    }

    enum Shortfall: Equatable {
        /// No unit of the target for these platforms it supports; empty when its platforms are unknown and it has
        /// no unit at all.
        case target(String, platforms: [IndexPlatform])
        /// Files of a target built for some of its platforms that have no unit of it.
        case files(String, [FilePath])
    }

    /// The module and platform of the units of each indexed file.
    func indexedUnits() -> [FilePath: Set<IndexedUnit>] {
        plan.sourceFiles.reduce(into: [:]) { result, entry in
            let units = entry.value.map { IndexedUnit(module: $0.unit.moduleName, platform: IndexPlatform(triple: $0.unit.target)) }
            result[entry.key.path.lexicallyNormalized(), default: []].formUnion(units)
        }
    }

    /// For each target, the platforms it supports without any unit of its module, else its files without a unit of
    /// its module. A target whose module is unknown, or appears in no unit of the index (its name may be set where the
    /// project driver cannot read it), is covered by units of any module for its files.
    static func shortfalls(
        expected: [String: Set<FilePath>],
        units: [FilePath: Set<IndexedUnit>],
        targets: [String: CoverageTarget]
    ) -> [Shortfall] {
        let indexedModules = Set(units.values.joined().map(\.module))

        return expected.sorted { $0.key < $1.key }.flatMap { target, files -> [Shortfall] in
            let coverage = targets[target]
            let platforms = coverage?.platforms ?? []
            let targetUnits = files.reduce(into: Set<IndexedUnit>()) { $0.formUnion(units[$1] ?? []) }
            let module = coverage?.moduleName.flatMap { indexedModules.contains($0) ? $0 : nil }
            let relevant = module.map { module in targetUnits.filter { $0.module == module } } ?? targetUnits

            guard !relevant.isEmpty else { return [.target(target, platforms: platforms.sorted())] }

            let missingPlatforms = platforms.subtracting(relevant.compactMap(\.platform))
            guard missingPlatforms.isEmpty else { return [.target(target, platforms: missingPlatforms.sorted())] }

            let unindexed = files.filter { (units[$0] ?? []).isDisjoint(with: relevant) }
            return unindexed.isEmpty ? [] : [.files(target, unindexed.sorted { $0.string < $1.string })]
        }
    }

    /// One message naming each target with the platforms it lacks, and the targets with files without index data.
    static func incompleteCoverageMessage(_ shortfalls: [Shortfall], storeList: String, relativeTo base: FilePath = .current, examples: Int = 3) -> String {
        let targets = shortfalls.compactMap { shortfall -> String? in
            guard case let .target(target, platforms) = shortfall else { return nil }

            return platforms.isEmpty ? "'\(target)'" : "'\(target)' on \(platforms.map(\.name).joined(separator: ", "))"
        }
        let files = shortfalls.compactMap { shortfall -> String? in
            guard case let .files(target, paths) = shortfall else { return nil }

            let shown = paths.prefix(examples).map { $0.starts(with: base) ? $0.relativeTo(base).string : $0.string }
            let more = paths.count > examples ? " and \(paths.count - examples) more" : ""
            return "\(paths.count) source file(s) of '\(target)' (\(shown.joined(separator: ", "))\(more))"
        }
        let parts = (targets.isEmpty ? [] : ["no index data for target(s) \(targets.joined(separator: ", "))"])
            + (files.isEmpty ? [] : ["no index data for \(files.joined(separator: ", "))"])

        return "The index data does not cover every scanned target: \(parts.joined(separator: "; ")) (index store: \(storeList)). Build these targets for each of their platforms into the index store, pass the index store of every platform with '--index-store-path', or leave a target out with 'exclude_targets'. Failing as '--strict-index-coverage' is set."
    }
}
