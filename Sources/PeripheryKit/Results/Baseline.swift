import Configuration
import Foundation
import Shared
import SourceGraph
import SystemPackage

/// A baseline set of declarations that are excluded from results.
///
/// The baseline of format `v1` holds the ids of the declarations (their USRs), which match a result of any rule. Its
/// first layout holds the ids only; its second gives each id the kind, the name and the file of the result it was
/// written for, so that a reviewer can read what a baseline holds. Matching only uses the ids, and both layouts are
/// read.
///
/// The baseline of format `v2`, `{"version": 2, "ids": [...]}`, holds the ids of the output v2, which include the
/// rule: a declaration baselined as redundant public is reported again once it becomes unused.
public enum Baseline: Equatable {
    case v1(usrs: [String])
    case v2(entries: [Entry])
    case outputV2(ids: [String])

    public struct Entry: Codable, Hashable {
        public let id: String
        /// What the id was written for. Absent for an entry carried over from a version 1 baseline.
        public let kind: String?
        public let name: String?
        /// The path of the file relative to the project root.
        public let file: String?

        public init(id: String, kind: String? = nil, name: String? = nil, file: String? = nil) {
            self.id = id
            self.kind = kind
            self.name = name
            self.file = file
        }

        /// The file is relative to the project root when it lies under it, compared component by component once both
        /// paths are normalized, and absolute otherwise.
        init(id: String, result: ScanResult, projectRoot: FilePath) {
            let path = result.declaration.location.file.path.lexicallyNormalized()
            let root = projectRoot.lexicallyNormalized()
            var relative = path

            self.init(
                id: id,
                kind: result.declaration.kind.rawValue,
                name: result.declaration.name,
                file: root.isAbsolute && relative.removePrefix(root) && !relative.isEmpty ? relative.string : path.string
            )
        }
    }

    public var format: BaselineFormat {
        switch self {
        case .v1, .v2: .v1
        case .outputV2: .v2
        }
    }

    public var entries: [Entry] {
        switch self {
        case let .v1(usrs):
            usrs.map { Entry(id: $0) }
        case let .v2(entries):
            entries
        case let .outputV2(ids):
            ids.map { Entry(id: $0) }
        }
    }

    /// The ids the baseline holds: USRs for the format `v1`, output v2 ids for the format `v2`.
    public var usrs: Set<String> {
        switch self {
        case let .v1(usrs):
            Set(usrs)
        case let .v2(entries):
            Set(entries.map(\.id))
        case let .outputV2(ids):
            Set(ids)
        }
    }

    /// The baseline that keeps only the entries of the results that a baseline matched, in the given format.
    public static func pruned(keeping matchedResults: [ScanResult], format: BaselineFormat = .v1, projectRoot: FilePath) -> Baseline {
        switch format {
        case .v1:
            .v2(entries: entries(of: matchedResults, projectRoot: projectRoot).values.sorted { $0.id < $1.id })
        case .v2:
            outputV2(of: matchedResults)
        }
    }

    /// The baseline `--write-baseline` writes in the given format: the results, and the entries of the baseline that
    /// was read, which are never dropped. A result replaces the entry of the same id. A baseline of the other format
    /// is converted through the results it matched (`matchedResults`), as its ids cannot be translated; its entries
    /// that match no result are dropped.
    public static func written(
        from results: [ScanResult],
        union existing: Baseline?,
        matchedResults: [ScanResult] = [],
        format: BaselineFormat = .v1,
        projectRoot: FilePath
    ) -> Baseline {
        let kept = existing.flatMap { $0.format == format ? $0 : nil }

        switch format {
        case .v1:
            var entries = Dictionary(uniqueKeysWithValues: (kept?.entries ?? []).map { ($0.id, $0) })
            entries.merge(Self.entries(of: kept == nil ? matchedResults : [], projectRoot: projectRoot)) { _, new in new }
            entries.merge(Self.entries(of: results, projectRoot: projectRoot)) { _, new in new }
            return .v2(entries: entries.values.sorted { $0.id < $1.id })
        case .v2:
            let converted = kept == nil ? outputV2(of: matchedResults).usrs : []
            return .outputV2(ids: (outputV2(of: results).usrs.union(converted).union(kept?.usrs ?? [])).sorted())
        }
    }

    private static func outputV2(of results: [ScanResult]) -> Baseline {
        .outputV2(ids: Set(results.map { OutputV2Id.id(of: $0) }).sorted())
    }

    private static func entries(of results: [ScanResult], projectRoot: FilePath) -> [String: Entry] {
        var entries: [String: Entry] = [:]

        for result in results {
            for usr in result.usrs where entries[usr] == nil {
                entries[usr] = Entry(id: usr, result: result, projectRoot: projectRoot)
            }
        }

        return entries
    }

    /// The file contents: pretty-printed with sorted keys, slashes left unescaped and a trailing newline, so that
    /// a diff shows what changed and the same baseline always gives the same bytes.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self) + Data("\n".utf8)
    }

    /// Writes the file atomically, so that an interrupted run never leaves a truncated baseline, and never over a
    /// symbolic link (see `OutputFile.write`).
    public func write(to path: FilePath) throws {
        try OutputFile.write(encoded(), to: path)
    }

    /// Reads a baseline file, reporting the key at fault when the file is not a baseline.
    public static func load(from path: FilePath) throws -> Baseline {
        let data = try Data(contentsOf: path.url)

        do {
            return try JSONDecoder().decode(Baseline.self, from: data)
        } catch let error as DecodingError {
            throw PeripheryError.usageError("Invalid baseline \(path.string): \(error.readableReason())")
        }
    }
}

/// Decides which results a baseline excludes.
///
/// A baseline of the format `v2` matches a result by its output v2 id only, which includes the rule. A baseline of
/// the format `v1` matches a result of any rule by the ids of its declaration. Besides the ids of the current version,
/// it recognises the ones earlier versions wrote, so that an existing baseline keeps working: the position based ids
/// of unused imports and empty extensions, and the absolute path of a String Catalog, which also matches the same
/// catalog in another checkout of the project.
struct BaselineMatcher {
    enum Match {
        case current
        case legacy
    }

    private let usrs: Set<String>
    private let format: BaselineFormat
    private let projectRoot: FilePath
    private let legacyCatalogSuffixes: Set<String>

    init(_ baseline: Baseline, projectRoot: FilePath) {
        usrs = baseline.usrs
        format = baseline.format
        self.projectRoot = projectRoot

        // The checkout that wrote an old entry is unknown, so each of its trailing paths is a candidate for the
        // path of the catalog relative to the project root.
        let absoluteCatalogPrefix = SyntheticUsr.localizedStringPrefix + "/"
        legacyCatalogSuffixes = usrs
            .filter { $0.hasPrefix(absoluteCatalogPrefix) }
            .reduce(into: []) { suffixes, entry in
                let path = entry.dropFirst(SyntheticUsr.localizedStringPrefix.count)

                for index in path.indices where path[index] == "/" {
                    suffixes.insert(String(path[index...]))
                }
            }
    }

    func match(_ result: ScanResult) -> Match? {
        if format == .v2 {
            return usrs.contains(OutputV2Id.id(of: result)) ? .current : nil
        }

        if !result.usrs.isDisjoint(with: usrs) {
            return .current
        }

        if !result.legacyUsrs(projectRoot: projectRoot).isDisjoint(with: usrs) {
            return .legacy
        }

        if matchesLegacyCatalogEntry(result) {
            return .legacy
        }

        return nil
    }

    /// The entries of the baseline that a matched result accounts for.
    func entries(matchedBy result: ScanResult) -> Set<String> {
        if format == .v2 {
            return Set([OutputV2Id.id(of: result)]).intersection(usrs)
        }

        var matched = result.usrs.union(result.legacyUsrs(projectRoot: projectRoot)).intersection(usrs)

        let suffixes = legacyCatalogSuffixes(of: result)
        if !suffixes.isEmpty {
            let absoluteCatalogPrefix = SyntheticUsr.localizedStringPrefix + "/"

            for suffix in suffixes {
                for entry in usrs where entry.hasPrefix(absoluteCatalogPrefix) && entry.hasSuffix(suffix) {
                    matched.insert(entry)
                }
            }
        }

        return matched
    }

    /// The entries of the baseline that no result matches.
    func staleEntries(given matchedEntries: Set<String>) -> [String] {
        usrs.subtracting(matchedEntries).sorted()
    }

    // MARK: - Private

    private func matchesLegacyCatalogEntry(_ result: ScanResult) -> Bool {
        legacyCatalogSuffixes(of: result).contains { legacyCatalogSuffixes.contains($0) }
    }

    /// The catalog-relative suffixes of a String Catalog key result, which legacy absolute-path entries end with.
    /// Empty when the baseline holds no legacy catalog entry.
    private func legacyCatalogSuffixes(of result: ScanResult) -> [String] {
        guard !legacyCatalogSuffixes.isEmpty, result.declaration.kind == .localizedString else { return [] }

        return result.usrs
            .filter { $0.hasPrefix(SyntheticUsr.localizedStringPrefix) }
            .map { "/" + $0.dropFirst(SyntheticUsr.localizedStringPrefix.count) }
    }
}

extension Baseline: Codable {
    private enum OutputV2Keys: String, CodingKey {
        case version
        case ids
    }

    /// The layouts of the format `v1`, coded as the cases of an enum: `{"v1": {"usrs": [...]}}` and
    /// `{"v2": {"entries": [...]}}`.
    private enum USRLayout: Codable {
        case v1(usrs: [String])
        case v2(entries: [Entry])
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: OutputV2Keys.self)

        guard container.contains(.version) else {
            switch try USRLayout(from: decoder) {
            case let .v1(usrs): self = .v1(usrs: usrs)
            case let .v2(entries): self = .v2(entries: entries)
            }
            return
        }

        let version = try container.decode(Int.self, forKey: .version)
        guard version == 2 else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: container, debugDescription: "unsupported baseline version \(version), expected 2")
        }

        self = try .outputV2(ids: container.decode([String].self, forKey: .ids))
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case let .v1(usrs):
            try USRLayout.v1(usrs: usrs).encode(to: encoder)
        case let .v2(entries):
            try USRLayout.v2(entries: entries).encode(to: encoder)
        case let .outputV2(ids):
            var container = encoder.container(keyedBy: OutputV2Keys.self)
            try container.encode(2, forKey: .version)
            try container.encode(ids, forKey: .ids)
        }
    }
}
