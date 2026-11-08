import Configuration
import Foundation
import Logger
import Shared
import SourceGraph
import SystemPackage

/// `json-v2`: a versioned document described by `schemas/output-v2.json`, with stable ids, rules, messages and
/// paths relative to the project root.
public final class JsonV2Formatter: OutputFormatter {
    static let schemaVersion = 2
    public static let requiresRelativePaths = true
    public static let pathsAreRootRelative = true

    public let configuration: Configuration
    public let logger: Logger
    public lazy var currentFilePath: FilePath = configuration.projectRoot.isEmpty ? .current : configuration.projectRoot
    /// The variants the scan built, as the summary names them.
    public var variants: [String] = []
    /// The lines `--explain` prints for each requested declaration, carried by its results.
    public var explanations: [Declaration: [String]] = [:]
    var toolVersion = PeripheryVersion

    public init(configuration: Configuration, logger: Logger) {
        self.logger = logger
        self.configuration = configuration
    }

    public func format(_ results: [ScanResult], colored _: Bool) throws -> String? {
        try serializeJSON(document(for: outputResults(results)))
    }

    /// The results of the output v2, sorted by location, then rule and id.
    func outputResults(_ results: [ScanResult]) -> [OutputV2Result] {
        results.map(outputResult).sorted {
            ($0.location, $0.rule.rawValue, $0.id) < ($1.location, $1.rule.rawValue, $1.id)
        }
    }

    // MARK: - Private

    private func outputResult(_ result: ScanResult) -> OutputV2Result {
        let declaration = result.declaration
        let descriptions = describe(result, colored: false)
        var asset: OutputV2Result.Asset?
        var related: [OutputV2Result.Related] = []

        switch result.annotation {
        case let .unusedAssetCatalogSymbol(symbol):
            asset = .init(name: symbol.assetName, paths: symbol.assetPaths.map { outputPath($0).string })
        case let .redundantProtocol(references, _):
            // `describe` lists the conformances after the result, in the order of `sortedReferences`.
            related = zip(sortedReferences(references), descriptions.dropFirst()).map { reference, description in
                .init(
                    id: OutputV2Id.id(ofConformance: reference),
                    rule: .redundantConformance,
                    message: description.1,
                    location: location(reference.location, end: nil),
                    declaration: reference.parent.map(declarationInfo)
                )
            }
            .sorted { ($0.location, $0.id) < ($1.location, $1.id) }
        default:
            break
        }

        let end = declaration.commentCommands.locationOverride == nil ? declaration.range?.end : nil

        return OutputV2Result(
            id: OutputV2Id.id(of: result),
            rule: result.rule,
            message: descriptions[0].1,
            location: location(declarationLocation(from: declaration), end: end),
            declaration: declarationInfo(declaration),
            asset: asset,
            variants: [],
            related: related,
            fixable: result.fixableKind != nil,
            explanation: explanations[declaration].map { .init(summary: $0[0], details: $0.dropFirst().map(trimmedDetail)) }
        )
    }

    private func trimmedDetail(_ line: String) -> String {
        line.trimmingCharacters(in: .whitespaces)
    }

    private func location(_ location: Location, end: SourcePosition?) -> OutputV2Result.Location {
        .init(path: outputPath(location).string, line: location.line, column: location.column, endLine: end?.line, endColumn: end?.column)
    }

    private func declarationInfo(_ declaration: Declaration) -> OutputV2Result.DeclarationInfo {
        .init(
            name: declaration.name,
            kind: declarationKind(from: declaration),
            accessibility: declaration.accessibility.value.rawValue,
            modules: declaration.location.file.modules.sorted(),
            usrs: declaration.usrs.sorted()
        )
    }

    private func document(for results: [OutputV2Result]) -> [String: Any] {
        let byRule = Dictionary(grouping: results, by: \.rule.rawValue).mapValues(\.count)

        return [
            "schemaVersion": Self.schemaVersion,
            "tool": ["name": "outskirts", "version": toolVersion],
            "run": [
                "projectRoot": currentFilePath.string,
                "variants": variants,
                "timings": [String: Any](),
                "files": fileDigests(of: results),
            ] as [String: Any],
            "results": results.map(\.jsonObject),
            "summary": ["total": results.count, "byRule": byRule] as [String: Any],
        ]
    }

    /// The SHA-256 of every file a result or a related result is in, keyed by root-relative path; null for a file
    /// that cannot be read.
    private func fileDigests(of results: [OutputV2Result]) -> [String: Any] {
        let paths = Set(results.flatMap { [$0.location.path] + $0.related.map(\.location.path) })
        var digests: [String: Any] = [:]

        for path in paths {
            let file = FilePath(path).makeAbsolute(relativeTo: currentFilePath)

            do {
                let data = try Data(contentsOf: file.url)
                digests[path] = "sha256:" + SHA256.hexDigest(of: data)
            } catch {
                logger.debug("Cannot read \(file.string) to record its digest: \(error.localizedDescription)")
                digests[path] = NSNull()
            }
        }

        return digests
    }
}
